local ffi = require("ffi")

ffi.cdef([[
    typedef struct {
        void* base;
        void* allocation;
        uint32_t allocation_protection;
        uint32_t reserved;
        size_t size;
        uint32_t state;
        uint32_t protection;
        uint32_t type;
        uint32_t reserved2;
    } skybox_memory_region;
    void* __stdcall GetCurrentProcess(void);
    int __stdcall ReadProcessMemory(void* process, const void* address, void* output, size_t size, size_t* read);
    int __stdcall WriteProcessMemory(void* process, void* address, const void* input, size_t size, size_t* written);
    void* __stdcall VirtualAlloc(void* address, size_t size, uint32_t type, uint32_t protection);
    int __stdcall VirtualFree(void* address, size_t size, uint32_t type);
    size_t __stdcall VirtualQuery(const void* address, skybox_memory_region* output, size_t size);
    int __stdcall VirtualProtect(void* address, size_t size, uint32_t protection, uint32_t* previous);
    int __stdcall FlushInstructionCache(void* process, const void* address, size_t size);
]])

local kernel = ffi.load("kernel32")
local process = kernel.GetCurrentProcess()
local transferred = ffi.new("size_t[1]")
local protection = ffi.new("uint32_t[1]")
local region = ffi.new("skybox_memory_region[1]")
local header = ffi.new("uint8_t[64]")

local function read(address, output, size)
    size = size or ffi.sizeof(output)
    return kernel.ReadProcessMemory(process, ffi.cast("const void*", address), output, size, transferred) ~= 0
        and tonumber(transferred[0]) == size
end

local signature = "F2 0F 10 8F ?? ?? ?? ?? 4C 8D 44 24 50 F3 0F 10 9F ?? ?? ?? ??"
local found = client.find_pattern("scenesystem.dll", signature)
assert(found, "Skybox color: render pattern not found in this game build")
local selection = ffi.cast("uint8_t*", found)
assert(read(selection, header), "Skybox color: cannot read render instructions")
local offsets = ffi.new("uint32_t[2]")
ffi.copy(offsets, header + 4, 4)
ffi.copy(offsets + 1, header + 17, 4)
assert(offsets[0] > 0 and offsets[0] < 0x1000 and offsets[1] == offsets[0] + 8,
    "Skybox color: unsupported color layout")
local destination = selection + 21
local original = ffi.new("uint8_t[10]", {0x48, 0x8D, 0x4D, 0xD0, 0xF2, 0x0F, 0x11, 0x4C, 0x24, 0x50})
local existing = ffi.new("uint8_t[10]")
assert(read(destination, existing), "Skybox color: cannot read render entry")
if existing[0] ~= 0xE9 or existing[5] ~= 0x90 or existing[9] ~= 0x90 then
    for index = 0, 9 do
        assert(existing[index] == original[index], "Skybox color: unexpected render instructions")
    end
end

local enabled = ui.checkbox("skybox color enable", false)
local color = ui.color("skybox color", 255, 255, 255, 255)
local intensity = ui.slider("intensity", 0, 5, 1, 2)
local block, control, patch
local installed, exposed = false, false

local function allocate()
    local target = tonumber(ffi.cast("uintptr_t", destination))
    local cursor = math.max(0x10000, math.floor((target - 0x7FFF0000) / 0x10000) * 0x10000)
    local limit = target + 0x7FFF0000
    while cursor < limit do
        if kernel.VirtualQuery(ffi.cast("const void*", cursor), region, ffi.sizeof(region)) == 0 then break end
        local base = tonumber(ffi.cast("uintptr_t", region[0].base))
        local finish = base + tonumber(region[0].size)
        if finish <= cursor then break end
        if region[0].state == 0x10000 then
            local candidate = math.max(cursor, math.ceil(base / 0x10000) * 0x10000)
            if candidate + 0x2000 <= math.min(finish, limit) then
                local memory = kernel.VirtualAlloc(ffi.cast("void*", candidate), 0x2000, 0x3000, 0x04)
                if memory ~= nil then return ffi.cast("uint8_t*", memory) end
            end
        end
        cursor = finish
    end
end

local function prepare()
    block = allocate()
    assert(block ~= nil, "Skybox color: cannot allocate the skybox render detour")
    control = block + 0x1000
    local code = {
        0x9C,
        0x80, 0x3D, 0, 0, 0, 0, 0,
        0x74, 0x10,
        0xF2, 0x0F, 0x10, 0x0D, 0, 0, 0, 0,
        0xF3, 0x0F, 0x10, 0x1D, 0, 0, 0, 0,
        0x9D
    }
    for index, byte in ipairs(code) do block[index - 1] = byte end
    ffi.cast("int32_t*", block + 3)[0] = control - (block + 8)
    ffi.cast("int32_t*", block + 14)[0] = (control + 4) - (block + 18)
    ffi.cast("int32_t*", block + 22)[0] = (control + 12) - (block + 26)
    ffi.copy(block + 27, original, 10)
    block[37], block[38] = 0xFF, 0x25
    ffi.cast("uint32_t*", block + 39)[0] = 0
    ffi.cast("uintptr_t*", block + 43)[0] = ffi.cast("uintptr_t", destination + 10)
    patch = ffi.new("uint8_t[10]", {0xE9, 0, 0, 0, 0, 0x90, 0x90, 0x90, 0x90, 0x90})
    ffi.cast("int32_t*", patch + 1)[0] = block - (destination + 5)
    if kernel.VirtualProtect(block, 0x1000, 0x20, protection) == 0 then
        kernel.VirtualFree(block, 0, 0x8000)
        block, control = nil, nil
        error("Skybox color: cannot protect the skybox render detour")
    end
    kernel.FlushInstructionCache(process, block, 51)
end

local function replace(expected, replacement)
    local current = ffi.new("uint8_t[10]")
    if not read(destination, current) or ffi.string(current, 10) ~= ffi.string(expected, 10) then return false end
    if kernel.VirtualProtect(destination, 10, 0x40, protection) == 0 then return false end
    local previous = protection[0]
    local changed = kernel.WriteProcessMemory(process, destination, replacement, 10, transferred) ~= 0
        and tonumber(transferred[0]) == 10
    kernel.VirtualProtect(destination, 10, previous, protection)
    kernel.FlushInstructionCache(process, destination, 10)
    return changed
end

local function restore()
    if control ~= nil then control[0] = 0 end
    if not installed then return true end
    if not replace(patch, original) then return false end
    installed = false
    return true
end

local lifetime = ffi.gc(ffi.new("uint8_t[1]"), function()
    restore()
    if block ~= nil and not exposed then kernel.VirtualFree(block, 0, 0x8000) end
end)

events.on("frame", function()
    if not lifetime then return end
    if not enabled:get() then
        assert(restore(), "Skybox color: cannot restore the skybox render instructions")
        return
    end
    if block == nil then prepare() end
    local red, green, blue = color:get()
    local multiplier = intensity:get() / 255
    local values = ffi.cast("float*", control + 4)
    values[0], values[1], values[2] = red * multiplier, green * multiplier, blue * multiplier
    control[0] = 1
    if not installed then
        assert(replace(original, patch), "Skybox color: cannot install the skybox render detour")
        installed, exposed = true, true
    end
end)

events.on("unload", function()
    if restore() then
        ffi.gc(lifetime, nil)
        if block ~= nil and not exposed then kernel.VirtualFree(block, 0, 0x8000) end
        lifetime = nil
    end
end)
