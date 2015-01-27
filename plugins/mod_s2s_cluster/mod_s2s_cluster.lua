-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2014 Sipwise GmbH <development@sipwise.com>
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:set_global();
module:depends("sipwise_cluster");

local ut = require "util.table";
local prosody = prosody;
local hosts = prosody.hosts;

local tostring, type = tostring, type;
local t_insert = table.insert;
local xpcall, traceback = xpcall, debug.traceback;
local NULL = {};
local jid_split = require "util.jid".split;

local add_task = require "util.timer".add_task;
local st = require "util.stanza";
local initialize_filters = require "util.filters".initialize;
local nameprep = require "util.encodings".stringprep.nameprep;
local new_xmpp_stream = require "util.xmppstream".new;
local s2sc_new_incoming = require "core.s2scmanager".new_incoming;
local s2sc_new_outgoing = require "core.s2scmanager".new_outgoing;
local s2sc_destroy_session = require "core.s2scmanager".destroy_session;
local uuid_gen = require "util.uuid".generate;
local cert_verify_identity = require "util.x509".verify_identity;
local fire_global_event = prosody.events.fire_event;

local s2scout = module:require("s2scout");

local connect_timeout = module:get_option_number("s2sc_timeout", 90);
local stream_close_timeout = module:get_option_number("s2sc_close_timeout", 5);
local opt_keepalives = module:get_option_boolean("s2sc_tcp_keepalives", module:get_option_boolean("tcp_keepalives", true));
local secure_auth = module:get_option_boolean("s2sc_secure_auth", false); -- One day...
local secure_domains, insecure_domains =
	module:get_option_set("s2sc_secure_domains", {})._items, module:get_option_set("s2sc_insecure_domains", {})._items;
local require_encryption = module:get_option_boolean("s2sc_require_encryption", false);

local sessions = module:shared("sessions");
local cluster = module:shared("/*/sipwise_cluster/cluster");
local log = module._log;

--- Handle stanzas to remote domains

local bouncy_stanzas = { message = true, presence = true, iq = true };
local function bounce_sendq(session, reason)
	local sendq = session.sendq;
	if not sendq then return; end
	session.log("info", "sending error replies for "..#sendq.." queued stanzas because of failed outgoing connection to "..tostring(session.to_host));
	local dummy = {
		type = "s2scin";
		send = function(s)
			(session.log or log)("error", "Replying to to an s2sc error reply, please report this! Traceback: %s", traceback());
		end;
		dummy = true;
	};
	for i, data in ipairs(sendq) do
		local reply = data[2];
		if reply and not(reply.attr.xmlns) and bouncy_stanzas[reply.name] then
			reply.attr.type = "error";
			reply:tag("error", {type = "cancel"})
				:tag("remote-server-not-found", {xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas"}):up();
			if reason then
				reply:tag("text", {xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas"})
					:text("Server-to-server connection failed: "..reason):up();
			end
			cluster.core_process_stanza(dummy, reply);
		end
		sendq[i] = nil;
	end
	session.sendq = nil;
end

-- Handles stanzas to existing s2sc sessions
function route_to_existing_session(event)
	local from_host, to_host, stanza = event.from_host, event.to_host, event.stanza;
	if not hosts[from_host] then
		local st_to_node, st_to_host, st_to_resource = jid_split(stanza.attr.to);
		if hosts[st_to_host] and hosts[st_to_host].s2scout then
			log("debug", "[session_outside] from_host:%s to_host:%s",
				tostring(from_host), tostring(to_host));
			from_host = st_to_host;
			log("debug", "event.from_host:%s from_host:%s",
				tostring(event.from_host), tostring(from_host));
		else
			log("warn", "Attempt to send stanza from %s - a host we don't serve", from_host);
			return false;
		end
	end
	--log("debug", "from_host:%s to_host:%s", tostring(from_host), tostring(to_host));
	if hosts[from_host].s2scout then
		local host = hosts[from_host].s2scout[to_host];
		if host then
			(host.log or log)("debug", "host.type:"..host.type);
			-- We have a connection to this host already
			if host.type == "s2scout_unauthed" and (stanza.name ~= "db:verify" or not host.dialback_key) then
				(host.log or log)("debug", "trying to send over unauthed s2scout to "..to_host);

				-- Queue stanza until we are able to send it
				if host.sendq then t_insert(host.sendq, {tostring(stanza), stanza.attr.type ~= "error" and stanza.attr.type ~= "result" and st.reply(stanza)});
				else host.sendq = { {tostring(stanza), stanza.attr.type ~= "error" and stanza.attr.type ~= "result" and st.reply(stanza)} }; end
				host.log("debug", "stanza [%s] queued ", stanza.name);
				return true;
			elseif host.type == "local" or host.type == "component" then
				log("error", "Trying to send a stanza to ourselves??")
				log("error", "Traceback: %s", traceback());
				log("error", "Stanza: %s", tostring(stanza));
				return false;
			elseif host.type == "s2sc_destroyed" then
				log("warn", "s2sc destroyed");
				return;
			else
				(host.log or log)("debug", "going to send stanza to "..to_host.." from "..from_host);
				-- FIXME
				if host.from_host ~= from_host then
					log("error", "WARNING! This might, possibly, be a bug, but it might not...");
					log("error", "We are going to send from %s instead of %s", tostring(host.from_host), tostring(from_host));
				end
				if host.sends2sc(stanza) then
					host.log("debug", "stanza sent over %s", host.type);
					return true;
				end
			end
		end
	end
end

-- Create a new outgoing session for a stanza
function route_to_new_session(event)
	local from_host, to_host, stanza = event.from_host, event.to_host, event.stanza;
	log("debug", "opening a new outgoing connection for this stanza");
	--log("debug", "from_host:%s to_host:%s stanza:%s",
	--	tostring(from_host), tostring(to_host), tostring(stanza));
	local host_session = s2sc_new_outgoing(from_host, to_host);

	-- Store in buffer
	host_session.bounce_sendq = bounce_sendq;
	host_session.sendq = { {tostring(stanza), stanza.attr.type ~= "error" and stanza.attr.type ~= "result" and st.reply(stanza)} };
	log("debug", "stanza [%s] queued until connection complete", tostring(stanza.name));
	s2scout.initiate_connection(host_session);
	if (not host_session.connecting) and (not host_session.conn) then
		log("warn", "Connection to %s failed already, destroying session...", to_host);
		s2sc_destroy_session(host_session, "Connection failed");
		return false;
	end
	return true;
end

function module.add_host(module)
	module:hook("route/remote_cluster", route_to_existing_session, -1);
	module:hook("route/remote_cluster", route_to_new_session, -10);
	module:hook("s2sc-authenticated", make_authenticated, -1);
end

-- Stream is authorised, and ready for normal stanzas
function mark_connected(session)
	local sendq, send = session.sendq, session.sends2sc;

	local from, to = session.from_host, session.to_host;

	session.log("info", "%s s2sc connection %s->%s complete", session.direction, from, to);

	local event_data = { session = session };
	if session.type == "s2scout" then
		fire_global_event("s2scout-established", event_data);
		hosts[from].events.fire_event("s2scout-established", event_data);
	else
		local host_session = hosts[to];
		session.send = function(stanza)
			return host_session.events.fire_event("route/remote_cluster", { from_host = to, to_host = from, stanza = stanza });
		end;

		fire_global_event("s2scin-established", event_data);
		hosts[to].events.fire_event("s2scin-established", event_data);
	end

	if session.direction == "outgoing" then
		if sendq then
			session.log("debug", "sending %d queued stanzas across new outgoing connection to %s", #sendq, session.to_host);
			for i, data in ipairs(sendq) do
				send(data[1]);
				sendq[i] = nil;
			end
			session.sendq = nil;
		end

		session.ip_hosts = nil;
		session.srv_hosts = nil;
	end
end

function make_authenticated(event)
	local session, host = event.session, event.host;
	if not session.secure then
		if require_encryption or (secure_auth and not(insecure_domains[host])) or secure_domains[host] then
			session:close({
				condition = "policy-violation",
				text = "Encrypted server-to-server communication is required but was not "
				       ..((session.direction == "outgoing" and "offered") or "used")
			});
		end
	end
	if not hosts[host] then
		session:close({ condition = "undefined-condition", text = "Attempt to authenticate as a host we don't serve" });
	end
	if session.type == "s2scout_unauthed" then
		session.type = "s2scout";
	elseif session.type == "s2scin_unauthed" then
		session.type = "s2scin";
		if host then
			if not session.hosts[host] then session.hosts[host] = {}; end
			session.hosts[host].authed = true;
		end
	elseif session.type == "s2scin" and host then
		if not session.hosts[host] then session.hosts[host] = {}; end
		session.hosts[host].authed = true;
	else
		return false;
	end
	session.log("debug", "connection %s->%s is now authenticated for %s", session.from_host, session.to_host, host);

	mark_connected(session);

	return true;
end

--- Helper to check that a session peer's certificate is valid
local function check_cert_status(session)
	local host = session.direction == "outgoing" and session.to_host or session.from_host
	local conn = session.conn:socket()
	local cert
	if conn.getpeercertificate then
		cert = conn:getpeercertificate()
	end

	if cert then
		local chain_valid, errors;
		if conn.getpeerverification then
			chain_valid, errors = conn:getpeerverification();
		elseif conn.getpeerchainvalid then -- COMPAT mw/luasec-hg
			chain_valid, errors = conn:getpeerchainvalid();
			errors = (not chain_valid) and { { errors } } or nil;
		else
			chain_valid, errors = false, { { "Chain verification not supported by this version of LuaSec" } };
		end
		-- Is there any interest in printing out all/the number of errors here?
		if not chain_valid then
			(session.log or log)("debug", "certificate chain validation result: invalid");
			for depth, t in pairs(errors or NULL) do
				(session.log or log)("debug", "certificate error(s) at depth %d: %s", depth-1, table.concat(t, ", "))
			end
			session.cert_chain_status = "invalid";
		else
			(session.log or log)("debug", "certificate chain validation result: valid");
			session.cert_chain_status = "valid";

			-- We'll go ahead and verify the asserted identity if the
			-- connecting server specified one.
			if host then
				if cert_verify_identity(host, "xmpp-server", cert) then
					session.cert_identity_status = "valid"
				else
					session.cert_identity_status = "invalid"
				end
				(session.log or log)("debug", "certificate identity validation result: %s", session.cert_identity_status);
			end
		end
	end
	(session.log or log)("debug", "fire event:s2sc-check-certificate");
	return module:fire_event("s2sc-check-certificate", { host = host, session = session, cert = cert });
end

--- XMPP stream event handlers

local stream_callbacks = { default_ns = "jabber:serverc", handlestanza =  cluster.core_process_stanza };

local xmlns_xmpp_streams = "urn:ietf:params:xml:ns:xmpp-streams";

function stream_callbacks.streamopened(session, attr)
	local send = session.sends2sc;

	session.version = tonumber(attr.version) or 0;

	-- TODO: Rename session.secure to session.encrypted
	if session.secure == false then
		session.secure = true;

		-- Check if TLS compression is used
		local sock = session.conn:socket();
		if sock.info then
			session.compressed = sock:info"compression";
		elseif sock.compression then
			session.compressed = sock:compression(); --COMPAT mw/luasec-hg
		end
	end

	if session.direction == "incoming" then
		-- Send a reply stream header

		-- Validate to/from
		local to, from = nameprep(attr.to), nameprep(attr.from);
		if not to and attr.to then -- COMPAT: Some servers do not reliably set 'to' (especially on stream restarts)
			session:close({ condition = "improper-addressing", text = "Invalid 'to' address" });
			return;
		end
		if not from and attr.from then -- COMPAT: Some servers do not reliably set 'from' (especially on stream restarts)
			session:close({ condition = "improper-addressing", text = "Invalid 'from' address" });
			return;
		end

		-- Set session.[from/to]_host if they have not been set already and if
		-- this session isn't already authenticated
		if session.type == "s2scin_unauthed" and from and not session.from_host then
			session.from_host = from;
		elseif from ~= session.from_host then
			session:close({ condition = "improper-addressing", text = "New stream 'from' attribute does not match original" });
			return;
		end
		if session.type == "s2scin_unauthed" and to and not session.to_host then
			session.to_host = to;
		elseif to ~= session.to_host then
			session:close({ condition = "improper-addressing", text = "New stream 'to' attribute does not match original" });
			return;
		end

		-- For convenience we'll put the sanitised values into these variables
		to, from = session.to_host, session.from_host;

		session.streamid = uuid_gen();
		(session.log or log)("debug", "Incoming s2sc received %s", st.stanza("stream:stream", attr):top_tag());
		if to then
			if not hosts[to] then
				-- Attempting to connect to a host we don't serve
				session:close({
					condition = "host-unknown";
					text = "This host does not serve "..to
				});
				return;
			elseif not hosts[to].modules.s2s_cluster then
				-- Attempting to connect to a host that disallows s2sc
				session:close({
					condition = "policy-violation";
					text = "Server-to-server communication is disabled for this host";
				});
				return;
			end
		end

		if not hosts[from] then
			session:close({ condition = "undefined-condition", text = "Attempt to connect from a host we don't serve" });
			return;
		end

		if session.secure and not session.cert_chain_status then
			if check_cert_status(session) == false then
				return;
			end
		end

		session:open_stream(session.to_host, session.from_host)
		if session.version >= 1.0 then
			local features = st.stanza("stream:features");

			if to then
				log("debug", "fire event:s2sc-stream-features");
				hosts[to].events.fire_event("s2sc-stream-features", { origin = session, features = features });
			else
				(session.log or log)("warn", "No 'to' on stream header from %s means we can't offer any features", from or session.ip or "unknown host");
			end

			log("debug", "Sending stream features: %s", tostring(features));
			send(features);
		end
	elseif session.direction == "outgoing" then
		-- If we are just using the connection for verifying dialback keys, we won't try and auth it
		if not attr.id then error("stream response did not give us a streamid!!!"); end
		session.streamid = attr.id;

		if session.secure and not session.cert_chain_status then
			if check_cert_status(session) == false then
				return;
			end
		end

		-- Send unauthed buffer
		-- (stanzas which are fine to send before dialback)
		-- Note that this is *not* the stanza queue (which
		-- we can only send if auth succeeds) :)
		local send_buffer = session.send_buffer;
		if send_buffer and #send_buffer > 0 then
			log("debug", "Sending s2sc send_buffer now...");
			for i, data in ipairs(send_buffer) do
				session.sends2sc(tostring(data));
				send_buffer[i] = nil;
			end
		end
		session.send_buffer = nil;

		-- If server is pre-1.0, don't wait for features, just do dialback
		if session.version < 1.0 then
			if not session.dialback_verifying then
				log("debug", "fire event:s2scout-authenticate-legacy");
				hosts[session.from_host].events.fire_event("s2scout-authenticate-legacy", { origin = session });
			else
				mark_connected(session);
			end
		end
	end
	session.notopen = nil;
end

function stream_callbacks.streamclosed(session)
	(session.log or log)("debug", "Received </stream:stream>");
	session:close(false);
end

function stream_callbacks.error(session, error, data)
	if error == "no-stream" then
		session:close("invalid-namespace");
	elseif error == "parse-error" then
		session.log("debug", "Server-to-server-cluster XML parse error: %s", tostring(error));
		session:close("not-well-formed");
	elseif error == "stream-error" then
		local condition, text = "undefined-condition";
		for child in data:children() do
			if child.attr.xmlns == xmlns_xmpp_streams then
				if child.name ~= "text" then
					condition = child.name;
				else
					text = child:get_text();
				end
				if condition ~= "undefined-condition" and text then
					break;
				end
			end
		end
		text = condition .. (text and (" ("..text..")") or "");
		session.log("info", "Session s2sc closed by remote with error: %s", text);
		session:close(nil, text);
	end
end

local function handleerr(err) log("error", "Traceback[s2sc]: %s", traceback(tostring(err), 2)); end
function stream_callbacks.handlestanza(session, stanza)
	if stanza.attr.xmlns == "jabber:client" then --COMPAT: Prosody pre-0.6.2 may send jabber:client
		stanza.attr.xmlns = nil;
	end
	stanza = session.filter("stanzas/in", stanza);
	if stanza then
		return xpcall(function () return cluster.core_process_stanza(session, stanza) end, handleerr);
	end
end

local listener = {};

--- Session methods
local stream_xmlns_attr = {xmlns='urn:ietf:params:xml:ns:xmpp-streams'};
local function session_close(session, reason, remote_reason)
	local log = session.log or log;
	if session.conn then
		if session.notopen then
			if session.direction == "incoming" then
				session:open_stream(session.to_host, session.from_host);
			else
				session:open_stream(session.from_host, session.to_host);
			end
		end
		if reason then -- nil == no err, initiated by us, false == initiated by remote
			if type(reason) == "string" then -- assume stream error
				log("debug", "Disconnecting %s[%s], <stream:error> is: %s", session.host or session.ip or "(unknown host)", session.type, reason);
				session.sends2sc(st.stanza("stream:error"):tag(reason, {xmlns = 'urn:ietf:params:xml:ns:xmpp-streams' }));
			elseif type(reason) == "table" then
				if reason.condition then
					local stanza = st.stanza("stream:error"):tag(reason.condition, stream_xmlns_attr):up();
					if reason.text then
						stanza:tag("text", stream_xmlns_attr):text(reason.text):up();
					end
					if reason.extra then
						stanza:add_child(reason.extra);
					end
					log("debug", "Disconnecting %s[%s], <stream:error> is: %s", session.host or session.ip or "(unknown host)", session.type, tostring(stanza));
					session.sends2sc(stanza);
				elseif reason.name then -- a stanza
					log("debug", "Disconnecting %s->%s[%s], <stream:error> is: %s", session.from_host or "(unknown host)", session.to_host or "(unknown host)", session.type, tostring(reason));
					session.sends2sc(reason);
				end
			end
		end

		session.sends2sc("</stream:stream>");
		function session.sends2sc() return false; end

		local reason = remote_reason or (reason and (reason.text or reason.condition)) or reason;
		session.log("info", "%s s2sc stream %s->%s closed: %s", session.direction, session.from_host or "(unknown host)", session.to_host or "(unknown host)", reason or "stream closed");

		-- Authenticated incoming stream may still be sending us stanzas, so wait for </stream:stream> from remote
		local conn = session.conn;
		if reason == nil and not session.notopen and session.type == "s2scin" then
			add_task(stream_close_timeout, function ()
				if not session.destroyed then
					session.log("warn", "Failed to receive a stream close response, closing connection anyway...");
					s2sc_destroy_session(session, reason);
					conn:close();
				end
			end);
		else
			s2sc_destroy_session(session, reason);
			conn:close(); -- Close immediately, as this is an outgoing connection or is not authed
		end
	end
end

function session_open_stream(session, from, to)
	local attr = {
		["xmlns:stream"] = 'http://etherx.jabber.org/streams',
		xmlns = 'jabber:serverc',
		version = session.version and (session.version > 0 and "1.0" or nil),
		["xml:lang"] = 'en',
		id = session.streamid,
		from = from, to = to,
	}
	if not from or (hosts[from] and hosts[from].modules.s2sc_dialback) then
		attr["xmlns:db"] = 'jabber:serverc:dialback';
	end

	session.sends2sc("<?xml version='1.0'?>");
	session.sends2sc(st.stanza("stream:stream", attr):top_tag());
	return true;
end

-- Session initialization logic shared by incoming and outgoing
local function initialize_session(session)
	local stream = new_xmpp_stream(session, stream_callbacks);
	session.stream = stream;

	session.notopen = true;

	function session.reset_stream()
		session.notopen = true;
		session.stream:reset();
	end

	session.open_stream = session_open_stream;

	local filter = session.filter;
	function session.data(data)
		data = filter("bytes/in", data);
		if data then
			local ok, err = stream:feed(data);
			if ok then return; end
			(session.log or log)("warn", "Received invalid XML: %s", data);
			(session.log or log)("warn", "Problem was: %s", err);
			session:close("not-well-formed");
		end
	end

	session.close = session_close;

	local handlestanza = stream_callbacks.handlestanza;
	function session.dispatch_stanza(session, stanza)
		return handlestanza(session, stanza);
	end

	add_task(connect_timeout, function ()
		if session.type == "s2scin" or session.type == "s2scout" then
			return; -- Ok, we're connected
		elseif session.type == "s2sc_destroyed" then
			return; -- Session already destroyed
		end
		-- Not connected, need to close session and clean up
		(session.log or log)("debug", "Destroying incomplete session %s->%s due to inactivity",
		session.from_host or "(unknown)", session.to_host or "(unknown)");
		session:close("connection-timeout");
	end);
end

function listener.onconnect(conn)
	conn:setoption("keepalive", opt_keepalives);
	local session = sessions[conn];
	if not session then -- New incoming connection
		session = s2sc_new_incoming(conn);
		sessions[conn] = session;
		session.log("debug", "Incoming s2sc connection");

		local filter = initialize_filters(session);
		local w = conn.write;
		session.sends2sc = function (t)
			log("debug", "sending: %s", t.top_tag and t:top_tag() or t:match("^([^>]*>?)"));
			if t.name then
				t = filter("stanzas/out", t);
			end
			if t then
				t = filter("bytes/out", tostring(t));
				if t then
					return w(conn, t);
				end
			end
		end

		initialize_session(session);
	else -- Outgoing session connected
		session:open_stream(session.from_host, session.to_host);
	end
end

function listener.onincoming(conn, data)
	local session = sessions[conn];
	if session then
		session.data(data);
	end
end

function listener.onstatus(conn, status)
	if status == "ssl-handshake-complete" then
		local session = sessions[conn];
		if session and session.direction == "outgoing" then
			session.log("debug", "Sending stream header...");
			session:open_stream(session.from_host, session.to_host);
		end
	end
end

function listener.ondisconnect(conn, err)
	local session = sessions[conn];
	if session then
		sessions[conn] = nil;
		if err and session.direction == "outgoing" and session.notopen then
			(session.log or log)("debug", "s2sc connection attempt failed: %s", err);
		end
		(session.log or log)("debug", "s2sc disconnected: %s->%s (%s)", tostring(session.from_host), tostring(session.to_host), tostring(err or "connection closed"));
		s2sc_destroy_session(session, err);
	end
end

function listener.register_outgoing(conn, session)
	session.direction = "outgoing";
	sessions[conn] = session;
	initialize_session(session);
end

function check_auth_policy(event)
	local host, session = event.host, event.session;
	local must_secure = secure_auth;

	if not must_secure and secure_domains[host] then
		must_secure = true;
	elseif must_secure and insecure_domains[host] then
		must_secure = false;
	end

	if must_secure and (session.cert_chain_status ~= "valid" or session.cert_identity_status ~= "valid") then
		module:log("warn", "Forbidding insecure connection to/from %s", host or session.ip or "(unknown host)");
		if session.direction == "incoming" then
			session:close({ condition = "not-authorized", text = "Your server's certificate is invalid, expired, or not trusted by "..session.to_host });
		else -- Close outgoing connections without warning
			session:close(false);
		end
		return false;
	end
end

module:hook("s2sc-check-certificate", check_auth_policy, -1);

s2scout.set_listener(listener);

module:hook("server-stopping", function(event)
	local reason = event.reason;
	for _, session in pairs(sessions) do
		session:close{ condition = "system-shutdown", text = reason };
	end
end,500);



module:provides("net", {
	name = "s2sc";
	listener = listener;
	default_port = 15269;
	encryption = "starttls";
	multiplex = {
		pattern = "^<.*:stream.*%sxmlns%s*=%s*(['\"])jabber:serverc%1.*>";
	};
});
