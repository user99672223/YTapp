#!/bin/bash
# usage: mcp.sh <method> <params-json>
H='-H Content-Type:application/json -H Accept:application/json,text/event-stream'
SID=$(curl -s -m 10 -X POST ${ATVLOADLY_MCP:-http://127.0.0.1:5533/mcp} $H -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"claude","version":"0"}}}' -D - -o /dev/null | grep -i mcp-session-id | awk '{print $2}' | tr -d '\r')
curl -s -m 10 -X POST ${ATVLOADLY_MCP:-http://127.0.0.1:5533/mcp} $H -H "Mcp-Session-Id: $SID" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
curl -s -m ${TIMEOUT:-600} -N -X POST ${ATVLOADLY_MCP:-http://127.0.0.1:5533/mcp} $H -H "Mcp-Session-Id: $SID" -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"$1\",\"params\":${2:-{\}}}" | sed -n 's/^data: //p'
