-- Holds the feature modules and passes KOReader events on to them.
--
-- A module is a table with:
--   id                 unique key, also used for its settings ("<id>.enabled")
--   name               menu label
--   default_enabled    whether it is on for a fresh install
--   init(ctx)          optional, called once when the plugin loads
--   menuItems(ctx)     optional, returns sub-items for its submenu
--   on<Event>(ctx,...) optional KOReader event handlers (onSuspend, onPageUpdate…)
--
-- Kept free of KOReader requires so it can be tested with plain luajit.

local Registry = {}
Registry.__index = Registry

function Registry.new(settings)
    return setmetatable({ settings = settings, modules = {} }, Registry)
end

function Registry:add(mod)
    assert(type(mod.id) == "string", "module needs an id")
    for _, m in ipairs(self.modules) do
        assert(m.id ~= mod.id, "duplicate module id: " .. mod.id)
    end
    table.insert(self.modules, mod)
end

function Registry:isEnabled(mod)
    local v = self.settings:read(mod.id .. ".enabled")
    if v == nil then return mod.default_enabled == true end
    return v == true
end

function Registry:setEnabled(mod, on)
    self.settings:save(mod.id .. ".enabled", on and true or false)
end

-- Calls handler `name` on every enabled module. One module failing must not
-- stop the others (a broken lock screen should not break sync), so each call
-- is protected and the error is passed to `on_error`.
function Registry:dispatch(name, ctx, on_error, ...)
    for _, mod in ipairs(self.modules) do
        local fn = mod[name]
        if fn and self:isEnabled(mod) then
            local ok, err = pcall(fn, ctx, ...)
            if not ok and on_error then on_error(mod.id, name, err) end
        end
    end
end

return Registry
