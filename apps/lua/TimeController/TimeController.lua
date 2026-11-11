local HUD_SCALE = 0.60 
local BASE_BTN_SIZE = 70 
local btnDiameter = BASE_BTN_SIZE * HUD_SCALE
local spacing = 10 * HUD_SCALE
local currentAlpha = 0 
local currentX = 30    
local currentY = 30    

local function changeTime(dir)
    ac.setWeatherTimeOffset(1800 * dir, true)
end

local function drawTCSStyleButton(label, x, y, size, dir, globalAlpha)
    local radius = size / 2
    local center = vec2(x + radius, y + radius)
    
    ui.setCursor(vec2(x, y))
    local clicked = ui.invisibleButton(label .. "_inv", vec2(size, size))
    if clicked then
        changeTime(dir)
    end
    
    local isHovered = ui.itemHovered()
    
    if globalAlpha < 0.01 then return end

    local circleColor
    local textColor
    
    if isHovered then
        circleColor = rgbm(0.75, 0, 0, 0.9 * globalAlpha) 
        textColor = rgbm(1, 1, 1, 1 * globalAlpha)
    else
        circleColor = rgbm(1, 1, 1, 0.7 * globalAlpha)
        textColor = rgbm(0, 0, 0, 0.9) 
    end

    ui.drawCircleFilled(center, radius, circleColor, 30)
    
    ui.setCursor(vec2(x, y)) 
    ui.pushDWriteFont('Segoe UI;Weight=Bold') 
    
    ui.dwriteTextAligned(
        label, 
        size * 0.5, 
        ui.Alignment.Center, 
        ui.Alignment.Center, 
        vec2(size, size), 
        false, 
        textColor
    )
    ui.popDWriteFont()
end

function windowMain(dt)
    local camMode = ac.getSim().driveableCameraMode
    
    -- Base Visibility
    local baseAlpha = 0.3 
    
    -- 
    if camMode == 3 then
        baseAlpha = 0.3 
    end

    local targetAlpha = baseAlpha
    
    if ui.windowHovered() then
        targetAlpha = 1.0
    end

    currentAlpha = currentAlpha + (targetAlpha - currentAlpha) * dt * 15
    
    -- Draw Interface
    drawTCSStyleButton("+", currentX, currentY, btnDiameter, 1, currentAlpha)
    drawTCSStyleButton("-", currentX, currentY + btnDiameter + spacing, btnDiameter, -1, currentAlpha)
end