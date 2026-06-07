local ui = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/topitbopit/dollarware/main/library.lua"
))()

-- Grab the ScreenGui reference immediately while we can find it
-- Dollarware stores its screen in uiScreen which parents to gethui() or CoreGui
local libGui = nil
do
    local coreGui = game:GetService("CoreGui")
    -- Check CoreGui first
    for _, v in ipairs(coreGui:GetChildren()) do
        if v:IsA("ScreenGui") and v:FindFirstChild("#main_frame", true) then
            libGui = v
            break
        end
    end
    -- If executor uses gethui(), check there instead
    if not libGui and gethui then
        local ok, hui = pcall(gethui)
        if ok and hui then
            for _, v in ipairs(hui:GetChildren()) do
                if v:IsA("ScreenGui") and v:FindFirstChild("#main_frame", true) then
                    libGui = v
                    break
                end
            end
        end
    end
    -- Last resort: search all ScreenGuis in PlayerGui too
    if not libGui then
        local playerGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
        for _, v in ipairs(playerGui:GetChildren()) do
            if v:IsA("ScreenGui") and v:FindFirstChild("#main_frame", true) then
                libGui = v
                break
            end
        end
    end
end
