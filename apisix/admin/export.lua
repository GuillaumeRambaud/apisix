-- File: apisix/admin/export.lua  (or apisix/dashboard/export.lua)
local core = require("apisix.core")
local yaml         = require("lyaml")
-- local admin_router = require("apisix.admin.init")  -- or whichever module defines admin routing  -- or whichever store interface APISIX uses
-- If APISIX uses a “store” abstraction, use that instead of raw etcd

local _M = {}

--- Utility to fetch all keys under a prefix
local function fetch_all(prefix)
    local ok, res = core.etcd:get(prefix, { prefix = true })
    if not ok then
        return nil, "failed to get " .. prefix
    end
    return res, nil
end

function _M.export_yaml_handler()
    _M.set_ctx_and_check_token()

    -- Gather data
    local routes, err = fetch_all("/apisix/admin/routes")
    if not routes then
        core.log.error("export: get routes failed: ", err)
        return core.response.exit(500, { error = "failed to fetch routes" })
    end
    core.log.info("export: fetched ", routes)

    local services, err2 = fetch_all("/apisix/admin/services")
    if not services then
        core.log.error("export: get services failed: ", err2)
        return core.response.exit(500, { error = "failed to fetch services" })
    end

    local upstreams, err3 = fetch_all("/apisix/admin/upstreams")
    if not upstreams then
        core.log.error("export: get upstreams failed: ", err3)
        return core.response.exit(500, { error = "failed to fetch upstreams" })
    end

    local consumers, err4 = fetch_all("/apisix/admin/consumers")
    if not consumers then
        core.log.error("export: get consumers failed: ", err4)
        return core.response.exit(500, { error = "failed to fetch consumers" })
    end

    local plugin_meta, err5 = fetch_all("/apisix/admin/plugin_metadata")
    if not plugin_meta then
        -- optional, you might ignore this or log
        core.log.warn("export: plugin_metadata not found: ", err5)
        plugin_meta = {}
    end

    -- Build export table
    local export_obj = {
        routes = routes.nodes or {},
        services = services.nodes or {},
        upstreams = upstreams.nodes or {},
        consumers = consumers.nodes or {},
        plugin_metadata = plugin_meta.nodes or {},
    }

    -- Clean up internal fields if needed
    -- e.g. remove `modify_index`, `create_index`, etc.
    local function clean(tbl)
        for _, v in ipairs(tbl) do
            v.modify_index = nil
            v.create_index = nil
            if v.value and type(v.value) == "table" then
                clean(v.value)  -- if nested
            end
        end
    end
    clean(export_obj.routes)
    clean(export_obj.services)
    clean(export_obj.upstreams)
    clean(export_obj.consumers)
    clean(export_obj.plugin_metadata)

    -- Convert to YAML  
    local yaml_str, yaml_err = yaml.serialize(export_obj)
    if not yaml_str then
        core.log.error("export: yaml.serialize failed: ", yaml_err)
        return core.response.exit(500, { error = "failed to serialize yaml" })
    end

    -- Return as attachment
    ngx.status = ngx.HTTP_OK
    ngx.header["Content-Type"] = "application/x-yaml"
    ngx.header["Content-Disposition"] = "attachment; filename=apisix-export.yaml"
    ngx.say(yaml_str)
end

function _M.get(conf, ctx)
    -- Fetch all configuration objects from etcd
    local res, _ = core.etcd:get("/apisix/routes", { prefix = true })
    local data = { routes = {} }

    if res and res.body and res.body.kvs then
        for _, kv in ipairs(res.body.kvs) do
            local val, err = core.json.decode(kv.value)
            if val then
                table.insert(data.routes, val)
            else
                core.log.error("decode error: ", err)
            end
        end
    end

    -- Convert to YAML
    local yaml_str = yaml.encode(data)

    -- Return 200 + YAML string with correct header
    return 200, yaml_str, {
        ["Content-Type"] = "application/x-yaml",
        ["Content-Disposition"] = 'attachment; filename="apisix-export.yaml"'
    }
end

-- Register the route with admin_router
-- admin_router:match("GET", "/apisix/admin/export", _M.export_yaml_handler)

return _M
