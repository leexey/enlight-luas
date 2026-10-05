local ffi = require("ffi")
local bit = require("bit")

assert(ui.combobox and entity.set_local_model, "This script requires the updated Enlight model API")

ffi.cdef([[
    typedef struct {
        unsigned long attributes;
        unsigned long creation_low, creation_high;
        unsigned long access_low, access_high;
        unsigned long write_low, write_high;
        unsigned long size_high, size_low;
        unsigned long reserved_first, reserved_second;
        wchar_t filename[260];
        wchar_t alternate[14];
    } enlight_model_find_data;
    void* __stdcall GetModuleHandleA(const char* name);
    unsigned long __stdcall GetModuleFileNameW(void* module, wchar_t* buffer, unsigned long size);
    unsigned long __stdcall GetFileAttributesW(const wchar_t* path);
    void* __stdcall FindFirstFileW(const wchar_t* path, enlight_model_find_data* data);
    int __stdcall FindNextFileW(void* handle, enlight_model_find_data* data);
    int __stdcall FindClose(void* handle);
    int __stdcall WideCharToMultiByte(unsigned int page, unsigned long flags, const wchar_t* input,
        int length, char* output, int size, const char* fallback, int* used_fallback);
    int __stdcall MultiByteToWideChar(unsigned int page, unsigned long flags, const char* input,
        int length, wchar_t* output, int size);
]])

local kernel = ffi.load("kernel32")
local invalid = ffi.cast("void*", ffi.cast("intptr_t", -1))
local selector = ui.combobox("Model", {"[ OFF ]"}, 1)
local page_text = ui.label("Scanning models...")
local models, filtered, page_models = {}, {}, {}
local page, page_size = 1, 63
local active_path = ""
local selector_index = 1
local scanner, model_root
local previous_page, next_page, refresh
local apply_selection, update_filter, update_page, start_scan

local function wide(text)
    local length = kernel.MultiByteToWideChar(65001, 8, text, #text, nil, 0)
    assert(length > 0, "Invalid UTF-8 model path")
    local buffer = ffi.new("wchar_t[?]", length + 1)
    kernel.MultiByteToWideChar(65001, 8, text, #text, buffer, length)
    return buffer
end

local function from_wide(buffer)
    local length = kernel.WideCharToMultiByte(65001, 0, buffer, -1, nil, 0, nil, nil)
    if length <= 1 then return "" end
    local result = ffi.new("char[?]", length)
    kernel.WideCharToMultiByte(65001, 0, buffer, -1, result, length, nil, nil)
    return ffi.string(result, length - 1)
end

local function attributes(path)
    return tonumber(kernel.GetFileAttributesW(wide(path)))
end

local validation_id = 0
local pending_path

local function validate_model(model, complete, current)
    local namespace = model.path:match("^(.*)/[^/]+$") .. "/"
    if namespace == "characters/models/" then namespace = nil end
    local game_directory = model_root:sub(1, -#"characters/models" - 1)
    local pending, visited = {{path = model.path, disk = model.disk}}, {}
    local resources, referenced = {}, {}
    local process
    local function parse_resource(resource, source)
            if #source < 16 then return "Invalid compiled resource: " .. resource.path end
            local size, header, version, table_offset, count = string.unpack("<I4I2I2I4I4", source)
            local table_start = 9 + table_offset
            if header ~= 12 or size > #source or count > 128 or table_start < 17 or table_start + count * 12 - 1 > #source then
                return "Invalid compiled resource header: " .. resource.path
            end
            for index = 0, count - 1 do
                local entry = table_start + index * 12
                if source:sub(entry, entry + 3) == "RERL" then
                    local offset, length = string.unpack("<I4I4", source, entry + 4)
                    local block = entry + 4 + offset
                    if length < 8 or block < 1 or block + length - 1 > #source then
                        return "Invalid resource references: " .. resource.path
                    end
                    local references, total = string.unpack("<I4I4", source, block)
                    local first = block + references
                    if total > 4096 or first < block or first + total * 16 - 1 > block + length - 1 then
                        return "Invalid resource reference table: " .. resource.path
                    end
                    for item = 0, total - 1 do
                        local position = first + item * 16 + 8
                        local relative = tonumber((string.unpack("<i8", source, position)))
                        local start = position + relative
                        local finish = start >= block and start < block + length and source:find("\0", start, true)
                        if not finish or finish >= block + length then return "Invalid resource name: " .. resource.path end
                        local dependency = source:sub(start, finish - 1):gsub("\\", "/")
                        if dependency:find("..", 1, true) or dependency:find(":", 1, true)
                            or dependency:sub(1, 1) == "/" or #dependency > 255 then
                            return "Invalid model dependency path"
                        end
                        if not referenced[dependency] then
                            referenced[dependency] = true
                            resources[#resources + 1] = dependency
                            if #resources > 256 then return "Model dependency limit exceeded" end
                        end
                        local own_asset = namespace and dependency:sub(1, #namespace) == namespace
                            or not namespace and dependency:find("/" .. model.name .. "/", 1, true)
                        if own_asset then
                            local disk = game_directory .. dependency .. "_c"
                            if not files.exists(disk) then return "Model asset missing: " .. dependency .. "_c" end
                            if dependency:match("%.vmat$") or dependency:match("%.vmdl$") then
                                pending[#pending + 1] = {path = dependency, disk = disk}
                            end
                        elseif files.exists(game_directory .. dependency .. "_c")
                            and (dependency:match("%.vmat$") or dependency:match("%.vmdl$")) then
                            pending[#pending + 1] = {path = dependency, disk = game_directory .. dependency .. "_c"}
                        end
                    end
                end
            end
        return nil
    end
    process = function()
        if current ~= validation_id then return end
        while #pending > 0 do
            local resource = table.remove(pending)
            if not visited[resource.path] then
                visited[resource.path] = true
                local ok, job = pcall(files.read_async, resource.disk, function(bytes, failure)
                    if current ~= validation_id then return end
                    if not bytes then complete(false, "Cannot read model asset: " .. tostring(failure)); return end
                    local parsed, problem = pcall(parse_resource, resource, bytes)
                    if not parsed then complete(false, "Cannot validate model assets: " .. tostring(problem)); return end
                    if problem then complete(false, problem); return end
                    process()
                end)
                if not ok then complete(false, "Cannot read model assets: " .. tostring(job)) end
                return
            end
        end
        complete(true, nil, resources)
    end
    process()
end

local function find_root()
    local module = kernel.GetModuleHandleA("client.dll")
    if module == nil then return nil end
    local buffer = ffi.new("wchar_t[32768]")
    local length = kernel.GetModuleFileNameW(module, buffer, 32768)
    if length == 0 or length >= 32768 then return nil end
    local path = from_wide(buffer):gsub("\\", "/")
    local directory = path:match("^(.*)/bin/win64/[^/]+$")
    return directory and directory .. "/characters/models" or nil
end

local function active_index()
    for index, model in ipairs(filtered) do
        if model.path == (pending_path or active_path) then return index end
    end
    return 0
end

update_page = function()
    local count = math.max(1, math.ceil(#filtered / page_size))
    page = math.max(1, math.min(page, count))
    local options, selected = {"[ OFF ]"}, 1
    page_models = {{path = ""}}
    local first = (page - 1) * page_size + 1
    for index = first, math.min(first + page_size - 1, #filtered) do
        local model = filtered[index]
        local name = model.display or model.name
        if #name > 128 then
            name = name:sub(1, 125)
            while not utf8.len(name) do name = name:sub(1, -2) end
            name = name .. "..."
        end
        options[#options + 1] = name
        page_models[#page_models + 1] = model
        if model.path == (pending_path or active_path) then selected = #options end
    end
    selector_index = selected
    selector:set_options(options, selected)
    page_text:set(string.format("%d models | page %d/%d", #filtered, page, count))
    previous_page:set_visible(count > 1):set_enabled(page > 1 and not scanner)
    next_page:set_visible(count > 1):set_enabled(page < count and not scanner)
    selector:set_enabled(not scanner)
    refresh:set_enabled(not scanner)
end

update_filter = function()
    filtered = {}
    for _, model in ipairs(models) do
        filtered[#filtered + 1] = model
    end
    local index = active_index()
    page = index > 0 and math.floor((index - 1) / page_size) + 1 or 1
    update_page()
end

apply_selection = function(model, release_on_failure)
    validation_id = validation_id + 1
    local current = validation_id
    local function finish(valid, failure, resources)
        if current ~= validation_id then return end
        if model.path ~= "" and selector:get() ~= selector_index then
            apply_selection(page_models[selector:get()] or {path = ""})
            return
        end
        pending_path = nil
        if valid then valid, failure = entity.set_local_model(model.path ~= "" and model.path or nil, resources) end
        if not valid then
            if release_on_failure then entity.set_local_model(nil); active_path = "" end
            print(tostring(failure))
            update_page()
            return
        end
        active_path = model.path
        update_page()
    end
    pending_path = model.path
    if model.path == "" then finish(true); return true end
    local flags = attributes(model.disk)
    if flags == 0xffffffff or bit.band(flags, 0x10) ~= 0 then
        finish(false, "Model file missing: " .. model.disk)
        return false
    end
    validate_model(model, finish, current)
    return true
end

selector:on_change(function(control)
    if control:get() == selector_index then return end
    local model = page_models[control:get()]
    if model and model.path ~= (pending_path or active_path) then
        apply_selection(model)
        update_page()
    end
end)

previous_page = ui.button("Previous page", function() page = page - 1; update_page() end)
next_page = ui.button("Next page", function() page = page + 1; update_page() end)
refresh = ui.button("Refresh models", function() start_scan() end)

local function close_scan()
    if scanner and scanner.handle then kernel.FindClose(ffi.gc(scanner.handle, nil)) end
    scanner = nil
end

local function finish_scan()
    local result = scanner.models
    close_scan()
    models = result
    table.sort(models, function(a, b)
        if a.name:lower() == b.name:lower() then return a.path < b.path end
        return a.name:lower() < b.name:lower()
    end)
    local counts = {}
    for _, model in ipairs(models) do counts[model.name] = (counts[model.name] or 0) + 1 end
    for _, model in ipairs(models) do
        if counts[model.name] > 1 then
            local folder = model.path:match("^characters/models/([^/]+)/") or "root"
            model.display = model.name .. " (" .. folder .. ")"
        end
    end
    local found
    for _, model in ipairs(models) do
        if model.path == active_path then found = model; break end
    end
    if found then
        apply_selection(found, true)
    elseif active_path ~= "" then
        entity.set_local_model(nil)
        active_path = ""
    end
    update_filter()
end

start_scan = function()
    validation_id = validation_id + 1
    pending_path = nil
    close_scan()
    model_root = find_root()
    if not model_root then update_page(); return end
    local flags = attributes(model_root)
    if flags == 0xffffffff or bit.band(flags, 0x10) == 0 then
        models = {}
        if active_path ~= "" then entity.set_local_model(nil); active_path = "" end
        update_filter()
        return
    end
    scanner = {directories = {model_root}, models = {}, visited = 0, data = ffi.new("enlight_model_find_data[1]")}
    update_page()
    page_text:set("Scanning models...")
end

events.on("frame", function()
    if not scanner then return end
    local started = os.clock()
    for _ = 1, 128 do
        if not scanner.handle then
            local directory = table.remove(scanner.directories)
            if not directory then finish_scan(); return end
            scanner.directory = directory
            local handle = kernel.FindFirstFileW(wide(directory .. "/*"), scanner.data)
            if handle ~= invalid then scanner.handle = ffi.gc(handle, kernel.FindClose) end
        end
        if scanner.handle then
            local record = scanner.data[0]
            local name = from_wide(record.filename)
            if name ~= "." and name ~= ".." then
                scanner.visited = scanner.visited + 1
                local full = scanner.directory .. "/" .. name
                if bit.band(record.attributes, 0x400) == 0 then
                    if bit.band(record.attributes, 0x10) ~= 0 then
                        scanner.directories[#scanner.directories + 1] = full
                    elseif name:lower():sub(-7) == ".vmdl_c" and not name:lower():find("arm", 1, true) then
                        local path = "characters/models" .. full:sub(#model_root + 1):sub(1, -8) .. ".vmdl"
                        if #path <= 255 then
                            scanner.models[#scanner.models + 1] = {name = name:sub(1, -8), path = path, disk = full}
                        end
                    end
                end
            end
            if kernel.FindNextFileW(scanner.handle, scanner.data) == 0 then
                kernel.FindClose(ffi.gc(scanner.handle, nil))
                scanner.handle = nil
            end
            if scanner.visited >= 20000 then finish_scan(); return end
        end
        if os.clock() - started >= 0.002 then return end
    end
end)

events.on("unload", function() validation_id = validation_id + 1; close_scan(); entity.set_local_model(nil) end)
start_scan()