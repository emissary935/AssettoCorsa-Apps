local settings = ac.storage{
    enabled = true,
    smoothRate = 8.0,
    smoothShifting = true,
    shiftSmoothRate = 10.0,
    enablePreload = true,
    preloadRpm = 0,
    shifterRestMode = false
}

-- Fallback/default values
if not settings.smoothRate or settings.smoothRate < 1.0 then
    settings.smoothRate = 8.0
end
if settings.enabled == nil then
    settings.enabled = true
end
if settings.smoothShifting == nil then
    settings.smoothShifting = true
end
if not settings.shiftSmoothRate or settings.shiftSmoothRate < 1.0 then
    settings.shiftSmoothRate = 10.0
end
if settings.enablePreload == nil then
    settings.enablePreload = true
end
if not settings.preloadRpm then
    settings.preloadRpm = 0
end
if settings.shifterRestMode == nil then
    settings.shifterRestMode = settings.asbrghmed or false
end

local visualSteer = 0
local visualSteerVelocity = 0.0
local carRoot = nil
local steerWheel = nil
local animPath = nil
local currentCarId = nil
local shiftPathUp = nil
local shiftPathDown = nil
local shiftPathManual = nil
local activeShiftPath = nil
local shiftType = "NONE"
local hasShiftAnim = false
local shiftState = "IDLE" 
local rawShiftProgress = 0.0
local rawShiftMix = 0.0
local shiftStartProgress = 0.0
local smoothedShiftProgress = 0.0
local smoothedShiftMix = 0.0
local shiftTimer = 0.0
local holdTimer = 0.0
local preloadHoldTimer = 0.0
local totalShiftTime = 0.65
local currentShiftDuration = 0.35
local reachFraction = 0.40
local shifterHoldFraction = 0.50
local activePreloadRpm = 6500
local redlineRpm = 7500
local lastGear = nil
local appliedWheelOffset = 0
local wasOverridingAnim = false
local wasGearUpPressed = false
local wasGearDownPressed = false

local function findAnimFile(carsFolder, candidates)
    for _, fname in ipairs(candidates) do
        local p = carsFolder .. '/animations/' .. fname
        if io.fileExists(p) then return p end
    end
    return nil
end

-- Damped steering spring interpolation 
local function smoothDamp(current, target, currentVelocity, smoothTime, maxSpeed, dt)
    smoothTime = math.max(0.0001, smoothTime)
    local omega = 2.0 / smoothTime
    local x = omega * dt
    local exp = 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
    local change = current - target
    local originalTo = target

    if maxSpeed then
        local maxChange = maxSpeed * smoothTime
        change = math.clamp(change, -maxChange, maxChange)
    end

    target = current - change
    local temp = (currentVelocity + omega * change) * dt
    local newVelocity = (currentVelocity - omega * temp) * exp
    local output = target + (change + temp) * exp

    if (originalTo - current > 0.0) == (output > originalTo) then
        output = originalTo
        newVelocity = (output - originalTo) / dt
    end

    return output, newVelocity
end

local function loadCarData()
    currentCarId = ac.getCarID(0)
    if not currentCarId then return end

    carRoot = ac.findNodes("carRoot:0")
    if carRoot and not carRoot:empty() then
        steerWheel = carRoot:findNodes("STEER_HR")
        if steerWheel and not steerWheel:empty() then
            steerWheel:storeCurrentTransformation()
        end
    end

    local carsFolder = ac.getFolder(ac.FolderID.ContentCars) .. '/' .. currentCarId
    animPath = findAnimFile(carsFolder, {'steer.ksanim', 'Steer.ksanim', 'STEER.ksanim'})

    -- Look for paddle shift animations
    shiftPathUp = findAnimFile(carsFolder, {'shift_up.ksanim', 'shift_UP.ksanim', 'car_shift_up.ksanim', 'paddle_up.ksanim', 'shift-up.ksanim'})
    shiftPathDown = findAnimFile(carsFolder, {'shift_dw.ksanim', 'shift_down.ksanim', 'shift_dn.ksanim', 'car_shift_dw.ksanim', 'paddle_down.ksanim', 'shift-down.ksanim', 'shift-dw.ksanim'})
    
    -- Look for manual stick shift animation
    shiftPathManual = findAnimFile(carsFolder, {'shift.ksanim', 'Shift.ksanim', 'car_shift.ksanim'})

    if shiftPathUp or shiftPathDown then
        shiftType = "PADDLE"
        hasShiftAnim = true
        activeShiftPath = shiftPathUp or shiftPathDown
    elseif shiftPathManual then
        shiftType = "MANUAL"
        hasShiftAnim = true
        activeShiftPath = shiftPathManual
    else
        shiftType = "NONE"
        hasShiftAnim = false
        activeShiftPath = nil
    end

    local car = ac.getCar(0)
    local lim = (car and car.rpmLimiter and car.rpmLimiter > 2000) and car.rpmLimiter or ((car and car.maxRpm and car.maxRpm > 2000) and car.maxRpm or 7500)
    redlineRpm = lim

    local cfg = ac.INIConfig.carData(0, 'driver3d.ini')
    local pTime = cfg:get('SHIFT_ANIMATION', 'POSITIVE_TIME', 250)
    local sTime = cfg:get('SHIFT_ANIMATION', 'STATIC_TIME', 100)
    local nTime = cfg:get('SHIFT_ANIMATION', 'NEGATIVE_TIME', 250)
    local totalMs = pTime + sTime + nTime
    if totalMs <= 0 then totalMs = 600 end
    totalShiftTime = totalMs / 1000
    reachFraction = math.clamp(pTime / totalMs, 0.25, 0.50)
    shifterHoldFraction = math.clamp((pTime + sTime * 0.5) / totalMs, 0.40, 0.60)

    local pr = cfg:get('SHIFT_ANIMATION', 'PRELOAD_RPM', 0)
    if pr and pr > 2000 and pr < (redlineRpm + 500) then
        activePreloadRpm = pr
    else
        activePreloadRpm = math.floor(redlineRpm * 0.90)
    end

    if settings.preloadRpm and settings.preloadRpm > 2000 then
        activePreloadRpm = settings.preloadRpm
    end

    shiftState = "IDLE"
    rawShiftProgress = 0.0
    rawShiftMix = 0.0
    shiftStartProgress = 0.0
    smoothedShiftProgress = 0.0
    smoothedShiftMix = 0.0
    shiftTimer = 0.0
    holdTimer = 0.0
    preloadHoldTimer = 0.0
    lastGear = nil
    wasGearUpPressed = false
    wasGearDownPressed = false
end

local function resetWheelAndAnim()
    if appliedWheelOffset ~= 0 and steerWheel and not steerWheel:empty() then
        steerWheel:rotate(vec3(0, 0, 1), -appliedWheelOffset)
        appliedWheelOffset = 0
    end
    if wasOverridingAnim and carRoot and not carRoot:empty() then
        carRoot:setAnimation(nil)
        wasOverridingAnim = false
    end
    visualSteerVelocity = 0.0
    shiftState = "IDLE"
    rawShiftProgress = 0.0
    rawShiftMix = 0.0
    shiftStartProgress = 0.0
    smoothedShiftProgress = 0.0
    smoothedShiftMix = 0.0
    shiftTimer = 0.0
    holdTimer = 0.0
    preloadHoldTimer = 0.0
    wasGearUpPressed = false
    wasGearDownPressed = false
end

function script.update(dt)
    local sim = ac.getSim()
    if sim and (sim.isPaused or not sim.isLive) then
        return
    end

    local car = ac.getCar(0)
    if not car then return end

    local carId = ac.getCarID(0)
    if not carId then return end

    if carId ~= currentCarId or not carRoot or not animPath then
        loadCarData()
    end

    if not settings.enabled then
        resetWheelAndAnim()
        lastGear = car.gear
        ac.debug("Status", "DISABLED")
        return
    end

    local physAngle = car.steer or 0
    local maxLock = (car.steerLock and car.steerLock > 0) and car.steerLock or 450
    local rawNormSteer = math.clamp(physAngle / maxLock, -1.0, 1.0)
    local baseSmoothTime = 1.0 / math.max(settings.smoothRate, 1.0)
    local speedFactor = 1.0 + math.clamp((car.speedKmh or 0) / 300.0, 0.0, 0.35)
    local effSmoothTime = baseSmoothTime * speedFactor

    visualSteer, visualSteerVelocity = smoothDamp(visualSteer, rawNormSteer, visualSteerVelocity, effSmoothTime, nil, dt)
    local visualAngle = visualSteer * maxLock

    -- Gear shifting detection
    if hasShiftAnim then
        local currentGear = car.gear or 0
        local rpm = car.rpm or 0

        -- We detect (or try to) wheelspin / tyre slip
        local isWheelspinning = false
        local carSpeed = car.speedKmh or 0
        local wheelSpeed = car.poweredWheelsSpeed or car.drivetrainSpeed or carSpeed
        if (wheelSpeed - carSpeed) > 7.0 then
            isWheelspinning = true
        elseif car.wheels then
            for i = 0, 3 do
                local w = car.wheels[i]
                if w and w.slipRatio and math.abs(w.slipRatio) > 0.20 then
                    isWheelspinning = true
                    break
                end
            end
        end

        local isNearRedline = settings.enablePreload 
            and (shiftType == "MANUAL") 
            and (activePreloadRpm > 0) 
            and (rpm >= activePreloadRpm) 
            and (car.gas > 0.3) 
            and (currentGear > 0) 
            and not isWheelspinning
            and (math.abs(physAngle) < 60.0)
        
        local gearUpPressed = ac.isControllerGearUpPressed()
        local gearDownPressed = ac.isControllerGearDownPressed()
        local isUp = (gearUpPressed and not wasGearUpPressed) or (lastGear ~= nil and currentGear > lastGear)
        local isDown = (gearDownPressed and not wasGearDownPressed) or (lastGear ~= nil and currentGear < lastGear and currentGear ~= 0 and lastGear ~= 0)
        wasGearUpPressed = gearUpPressed
        wasGearDownPressed = gearDownPressed

        if isUp then
            activeShiftPath = shiftPathUp or shiftPathManual or shiftPathDown
            currentShiftDuration = (activeShiftPath == shiftPathManual) and totalShiftTime or 0.32
        elseif isDown then
            activeShiftPath = shiftPathDown or shiftPathManual or shiftPathUp
            currentShiftDuration = (activeShiftPath == shiftPathManual) and totalShiftTime or 0.32
        end

        if isUp or isDown then
            local wasHolding = (shiftState == "HOLD")
            shiftState = "SHIFTING"
            rawShiftMix = 1.0
            preloadHoldTimer = 0.0
            local isTargetingHold = settings.shifterRestMode and (shiftType == "MANUAL") and (currentGear >= 3)
            local targetProgress = isTargetingHold and shifterHoldFraction or 1.0

            if isTargetingHold then
                if wasHolding then
                    if isUp then
                        holdTimer = holdTimer + 3.0
                    else
                        holdTimer = math.max(holdTimer, 3.0)
                    end
                else
                    holdTimer = 5.0
                end
            else
                holdTimer = 0.0
            end

            if shiftType == "MANUAL" and rawShiftProgress > 0.05 then
                if isTargetingHold and rawShiftProgress >= (shifterHoldFraction - 0.05) then
                    shiftStartProgress = math.max(reachFraction - 0.05, 0.32)
                    currentShiftDuration = math.max(totalShiftTime * 0.40, 0.20)
                else
                    shiftStartProgress = rawShiftProgress
                    local remaining = math.max(targetProgress - shiftStartProgress, 0.15)
                    currentShiftDuration = totalShiftTime * remaining
                end
            else
                shiftStartProgress = 0.0
                currentShiftDuration = (shiftType == "MANUAL") and (totalShiftTime * targetProgress) or 0.32
            end
            shiftTimer = currentShiftDuration
        end
        lastGear = currentGear

        
        if shiftState == "SHIFTING" then
            rawShiftMix = 1.0
            shiftTimer = shiftTimer - dt
            local isTargetingHold = settings.shifterRestMode and (shiftType == "MANUAL") and (currentGear >= 3)
            local targetProgress = isTargetingHold and shifterHoldFraction or 1.0
            local t = math.clamp(1.0 - (shiftTimer / currentShiftDuration), 0.0, 1.0)
            rawShiftProgress = math.lerp(shiftStartProgress, targetProgress, t)

            if shiftTimer <= 0 then
                if isTargetingHold then
                    shiftState = "HOLD"
                    rawShiftProgress = targetProgress
                    rawShiftMix = 1.0
                else
                    rawShiftProgress = 0.0
                    rawShiftMix = 0.0
                    shiftStartProgress = 0.0
                    shiftState = "IDLE"
                    holdTimer = 0.0
                end
            end
        elseif shiftState == "HOLD" then
            if not settings.shifterRestMode or currentGear < 3 or shiftType ~= "MANUAL" then
                shiftState = "IDLE"
                rawShiftMix = 0.0
                rawShiftProgress = 0.0
                shiftStartProgress = 0.0
                holdTimer = 0.0
            else
                holdTimer = holdTimer - dt
                if holdTimer <= 0 then
                    if isNearRedline then
                        shiftState = "PRELOAD"
                        if shiftPathManual then activeShiftPath = shiftPathManual end
                        rawShiftMix = 1.0
                        rawShiftProgress = reachFraction
                        preloadHoldTimer = 1.2
                        holdTimer = 0.0
                    else
                        shiftState = "IDLE"
                        rawShiftMix = 0.0
                        rawShiftProgress = 0.0
                        shiftStartProgress = 0.0
                        holdTimer = 0.0
                    end
                else
                    rawShiftProgress = shifterHoldFraction
                    rawShiftMix = 1.0
                end
            end
        elseif isNearRedline then
            shiftState = "PRELOAD"
            if shiftPathManual then activeShiftPath = shiftPathManual end
            rawShiftMix = 1.0
            if rawShiftProgress < reachFraction then
                rawShiftProgress = math.min(rawShiftProgress + (dt / 0.25), reachFraction)
            else
                rawShiftProgress = reachFraction
            end
            if rawShiftProgress >= (reachFraction * 0.70) then
                preloadHoldTimer = 1.2
            end
        else
            if shiftState == "PRELOAD" or rawShiftMix > 0 then
                if preloadHoldTimer > 0 then
                    preloadHoldTimer = preloadHoldTimer - dt
                    rawShiftProgress = reachFraction
                    rawShiftMix = 1.0
                else
                    rawShiftProgress = math.max(rawShiftProgress - (dt / 0.40), 0.0)
                    rawShiftMix = math.max(rawShiftMix - dt * 2.5, 0.0)
                    if rawShiftMix <= 0.01 and rawShiftProgress <= 0.01 then
                        rawShiftMix = 0.0
                        rawShiftProgress = 0.0
                        shiftState = "IDLE"
                    end
                end
            end
        end

        if settings.smoothShifting then
            local sRate = math.max(settings.shiftSmoothRate, 1.0)
            smoothedShiftProgress = math.lerp(smoothedShiftProgress, rawShiftProgress, 1 - math.exp(-sRate * dt))
            smoothedShiftMix = math.lerp(smoothedShiftMix, rawShiftMix, 1 - math.exp(-sRate * dt))
        else
            smoothedShiftProgress = rawShiftProgress
            smoothedShiftMix = rawShiftMix
        end
    else
        lastGear = car.gear
        shiftState = "IDLE"
        rawShiftMix = 0.0
        rawShiftProgress = 0.0
        smoothedShiftMix = 0.0
        smoothedShiftProgress = 0.0
        wasGearUpPressed = false
        wasGearDownPressed = false
    end

    if carRoot and animPath then
        local armSteer = -visualSteer
        local progress = math.clamp((armSteer + 1.0) * 0.5, 0.0, 1.0)
        carRoot:setAnimation(animPath, progress, true)
        wasOverridingAnim = true

        if hasShiftAnim and smoothedShiftMix > 0.01 and activeShiftPath then
            carRoot:blendAnimation(activeShiftPath, smoothedShiftProgress, smoothedShiftMix)
        end

        local targetOffset = 0
        if steerWheel and not steerWheel:empty() then
            targetOffset = math.rad(visualAngle - physAngle)
        end

        local deltaOffset = targetOffset - appliedWheelOffset
        if math.abs(deltaOffset) > 0.0001 and steerWheel and not steerWheel:empty() then
            steerWheel:rotate(vec3(0, 0, 1), deltaOffset)
            appliedWheelOffset = targetOffset
        end

        local currentGear = car.gear or 0
        local gearLabel = currentGear == 0 and "N" or (currentGear == -1 and "R" or tostring(currentGear))
        local typeLabel = shiftType == "PADDLE" and "PADDLES" or (shiftType == "MANUAL" and "H-STICK" or "NONE")
        local stateDetail = shiftState
        if shiftState == "PRELOAD" or shiftState == "SHIFTING" then
            stateDetail = string.format("%s (%.0f%%)", shiftState, smoothedShiftProgress * 100)
        elseif shiftState == "HOLD" then
            stateDetail = string.format("REST MODE (%s HELD %.1fs)", gearLabel, holdTimer)
        end

        ac.debug("Status", "ACTIVE")
        ac.debug("Gear", string.format("%s | %.0f / %.0f RPM", gearLabel, car.rpm or 0, activePreloadRpm))
        ac.debug("Shift", string.format("[%s] %s", typeLabel, stateDetail))
        ac.debug("PhysSteer", string.format("%.1f deg", physAngle))
        ac.debug("VisualSteer", string.format("%.1f deg", visualAngle))
    else
        ac.debug("Status", animPath and "NO CAR ROOT" or "steer.ksanim NOT FOUND")
    end
end

function windowMain(dt)
    if ui.checkbox("Enable filter", settings.enabled) then
        settings.enabled = not settings.enabled
        if not settings.enabled then
            resetWheelAndAnim()
        end
    end

    ui.setNextItemWidth(140)
    settings.smoothRate = ui.slider("##smoothRate", settings.smoothRate, 2.0, 30.0, "Smoothness: %.1f")

    if hasShiftAnim then
        ui.separator()
        if ui.checkbox("Smooth shift animation", settings.smoothShifting) then
            settings.smoothShifting = not settings.smoothShifting
        end
        if settings.smoothShifting then
            ui.setNextItemWidth(140)
            settings.shiftSmoothRate = ui.slider("##shiftSmoothRate", settings.shiftSmoothRate, 2.0, 30.0, "Shift smoothness: %.1f")
        end
        if shiftType == "MANUAL" then
            if ui.checkbox("Preload hand on redline", settings.enablePreload) then
                settings.enablePreload = not settings.enablePreload
                if not settings.enablePreload and shiftState == "PRELOAD" then
                    shiftState = "IDLE"
                    rawShiftMix = 0.0
                    rawShiftProgress = 0.0
                    preloadHoldTimer = 0.0
                end
            end
            if ui.checkbox("Shifter rest mode (5s in 3rd, +3s per upshift)", settings.shifterRestMode) then
                settings.shifterRestMode = not settings.shifterRestMode
                if not settings.shifterRestMode and shiftState == "HOLD" then
                    shiftState = "IDLE"
                    rawShiftMix = 0.0
                    rawShiftProgress = 0.0
                    shiftStartProgress = 0.0
                    holdTimer = 0.0
                end
            end
        end
    end

    if not animPath then
        ui.textColored("steer.ksanim not found!", rgbm(1, 0.3, 0.3, 1))
    end
end
