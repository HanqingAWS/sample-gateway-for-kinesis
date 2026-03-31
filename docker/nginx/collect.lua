local cjson = require "cjson"
local http = require "resty.http"

-- Get request path and all query string parameters
local uri = ngx.var.uri
local args, err = ngx.req.get_uri_args(0)

if not args then
    ngx.status = 400
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"bad request"}')
    return
end

-- Build JSON object: flatten all query string params as key-value strings
-- Matches API Gateway VTL behavior: all values are strings
local data = {}
data["_path"] = uri  -- metadata for Vector routing, will be removed before Kinesis

for key, val in pairs(args) do
    if type(val) == "table" then
        -- Duplicate params: take the last value (matches API Gateway behavior)
        data[key] = tostring(val[#val])
    else
        data[key] = tostring(val)
    end
end

-- Encode as JSON
local json_body = cjson.encode(data)

-- POST to Vector HTTP source
local httpc = http.new()
httpc:set_timeout(5000)

-- VECTOR_HOST/VECTOR_PORT set in init_by_lua_block (nginx.conf)
-- Defaults: 127.0.0.1:8686 (works in both Docker Compose and ECS Fargate)
local vector_host = VECTOR_HOST or "127.0.0.1"
local vector_port = VECTOR_PORT or "8686"
local res, send_err = httpc:request_uri("http://" .. vector_host .. ":" .. vector_port .. "/", {
    method = "POST",
    body = json_body,
    headers = {
        ["Content-Type"] = "application/json",
    },
})

if not res then
    ngx.log(ngx.ERR, "failed to send to vector: ", send_err)
end

-- Return 200 immediately to ad platform (don't wait for Kinesis write)
ngx.status = 200
ngx.header["Content-Type"] = "application/json"
ngx.say('{"status":"ok"}')
