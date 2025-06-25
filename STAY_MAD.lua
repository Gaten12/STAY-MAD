package.path = "C:\\plaguecheat.cc\\lib\\?.lua;" .. package.path
local GUI = require("gui")
local bit = require("bit")

local ffi = require("ffi")
ffi.cdef([[
    typedef struct {
        unsigned long type;
        union {
            struct {
                long dx;
                long dy;
                unsigned long mouseData;
                unsigned long dwFlags;
                unsigned long time;
                uintptr_t dwExtraInfo;
            } mi;
        };
    } INPUT;
    
    unsigned int SendInput(unsigned int nInputs, INPUT* pInputs, int cbSize);
    void Sleep(unsigned long dwMilliseconds);
]])

local INPUT_MOUSE = 0
local MOUSEEVENTF_MOVE = 1
local MOUSEEVENTF_LEFTDOWN = 2
local MOUSEEVENTF_LEFTUP = 4

GUI.Initialize() 
Renderer.LoadFontFromFile("TahomaDebug23", "Tahoma", 12, true)

local blockbot_enable = Menu.Checker("Blockbot Enable", false, false, true)
local blocking_mode_combo = Menu.Combo("Blocking Mode", 0, {"View Angles", "Front Block", "Pusher Mode"})
local autojump_enable = Menu.Checker("Auto Jump", false)

-- Custom color settings for visuals
local circle_color = Menu.Checker("Circle Color", false, true)
local on_head_color = Menu.Checker("On Head Color", false, true)
local mode_indicator_color = Menu.Checker("Mode Indicator Color", false, true)

--// GLOBAL STATE VARIABLES //--
local blockEnemy = nil
local currentTarget = nil

-- Visual smoothing
local lastDrawnTeammatePos = nil
local INTERPOLATION_ALPHA = 0.2 -- Smoothing factor for visual indicators

-- Auto-jump state
local bot_has_active_jump_command = false

-- Acceleration prediction state
local prev_block_enemy_ref_for_accel = nil
local prev_target_pos_for_accel = nil
local prev_target_vel_for_accel = nil
local prev_actual_frame_time_for_accel_calc = 0.015625 -- Default reasonable frametime

-- ADAD (A-D-A-D strafing pattern) Detection State
local prev_lateral_offset_sign_for_adad = 0 -- Stores the sign of the target's lateral movement relative to us (-1 left, 0 center, 1 right)
local adad_active_timer = 0                 -- Timer to keep ADAD countermeasures active for a short duration
local last_lateral_change_time = 0          -- Timestamp of the last lateral direction change
local adad_rhythm_streak = 0                -- Counts consecutive rhythmic ADAD reversals

-- Animated Circle State
local animated_circle_phase = 0 -- Phase for the up/down animation of the circle

--// CONSTANTS //--

-- General
local MAX_PLAYER_SPEED = 250
local MAX_PREDICTION_FRAMETIME = 0.033 -- Cap prediction frametime to avoid issues with extreme lag spikes (approx 30 FPS)
local AUTOJUMP_TARGET_Z_VEL_THRESHOLD = 200 -- Minimum vertical speed of target to trigger autojump (UPDATED FROM 100 TO 200)
local MAX_CORRECTION_DISTANCE = 100 -- Define this constant for correction speed calculation

-- On-Head Blocking Mode
local ON_HEAD_PREDICTION_FRAMES = 10
local ON_HEAD_DEADZONE_HORIZONTAL = 1
local ON_HEAD_HEIGHT_OFFSET = 72         -- How far above the target's head we aim to be
local ON_HEAD_Z_THRESHOLD = 5            -- Minimum Z distance above target to be considered "on head"
local ON_HEAD_XY_TOLERANCE = 15
local ON_HEAD_CORRECTION_TIMESCALE_FRAMES = 0.5 -- How quickly to correct position (in frames)
local ON_HEAD_CORRECTION_GAIN = 15       -- Multiplier for correction speed

-- Front Block Mode (Aggressive blocking in front of the teammate)
local FRONT_BLOCK_DISTANCE = 35          -- How far in front of the teammate to position
local FRONT_BLOCK_HEIGHT_OFFSET = 0      -- Vertical offset for the block position
local FRONT_BLOCK_DEADZONE_HORIZONTAL = 5
local FRONT_BLOCK_PREDICTION_FRAMES = 4
local FRONT_BLOCK_CORRECTION_TIMESCALE_FRAMES = 0.15
local FRONT_BLOCK_CORRECTION_GAIN = 35
local FRONT_BLOCK_VELOCITY_THRESHOLD_FOR_DIRECTION = 50 -- Min speed for target to use their velocity dir for front block

-- View Angles Mode (Side-to-side blocking, with ADAD adaptation)
local VIEW_ANGLES_MAX_STRAFE_POWER_BASE = 1.0
local VIEW_ANGLES_MAX_STRAFE_POWER_ADAD = 1.0

local VIEW_ANGLES_PREDICTION_FRAMES_ACCEL_BASE_MIN = 1
local VIEW_ANGLES_PREDICTION_FRAMES_ACCEL_BASE_MAX = 4
local VIEW_ANGLES_PREDICTION_FRAMES_ACCEL_ADAD = 1

local VIEW_ANGLES_ACCEL_DAMPING_FACTOR = 0.85

local VIEW_ANGLES_LATERAL_OFFSET_DEADZONE_BASE = 0.2
local VIEW_ANGLES_LATERAL_OFFSET_DEADZONE_ADAD = 0.05

local VIEW_ANGLES_MIN_VALID_PREV_FRAME_TIME = 0.001

-- ADAD Detection Specific Constants
local ADAD_DETECTION_MIN_SPEED_XY = 70
local ADAD_COUNTER_DURATION_SECONDS = 0.3
local ADAD_MIN_LATERAL_OFFSET_FOR_SIGN = 0.1
local ADAD_RHYTHM_WINDOW_SECONDS = 0.15
local ADAD_MIN_RHYTHM_COUNT = 2

-- Animated Circle Visuals
local ANIMATED_CIRCLE_RADIUS = 30 
local ANIMATED_CIRCLE_SPEED = 2.0
local ANIMATED_CIRCLE_HEIGHT_RANGE = 72 
local ANIMATED_CIRCLE_BASE_Z_OFFSET = 0 

local esp_color = Color(255, 100, 0, 255) 
local gui_initialized = false
local player_esp_states = {} 
local enemy_gui_elements = { slots = {}, page_label = nil }
local teammate_gui_elements = { slots = {}, page_label = nil }
local enemy_page_state = { current_page = 1, items_per_page = 10, total_pages = 1 }
local teammate_page_state = { current_page = 1, items_per_page = 10, total_pages = 1 }
local esp_settings = {
    show_box = true,
    show_name = true,
    show_distance = true,
    show_health_bar = true,
    show_line = true
}

local grief_settings = {
    grenade_griefer = true,
    weapon_stealer = true,
    defuse_blocker = true,
    molotov_grief = true,
    fov = 50,
    show_fov = true
}

local function DrawGriefFOV()
    -- Mengambil nilai dari tabel settings yang sudah benar
    if not grief_settings or not grief_settings.show_fov then return end

    local screenSize = Renderer.GetScreenSize()
    if not screenSize then return end

    local centerX, centerY = screenSize.x / 2, screenSize.y / 2
    
    -- Mengambil nilai FOV langsung dari tabel
    local fovRadius = grief_settings.fov
    local circleColor = Color(255, 255, 255, 80) -- Warna putih semi-transparan

    for i = 0, 360, 15 do
        local angle1 = math.rad(i)
        local angle2 = math.rad(i + 15)
        
        local x1 = centerX + (math.cos(angle1) * fovRadius)
        local y1 = centerY + (math.sin(angle1) * fovRadius)
        
        local x2 = centerX + (math.cos(angle2) * fovRadius)
        local y2 = centerY + (math.sin(angle2) * fovRadius)
        
        Renderer.DrawLine(Vector2D(x1, y1), Vector2D(x2, y2), circleColor, 1) 
    end
end

local function fmod(a, b)
    return a - math.floor(a / b) * b
end

local function NormalizeYaw(yaw)
    local sign = 1
    if yaw < 0 then sign = -1 end
    return (fmod(math.abs(yaw) + 180, 360) - 180) * sign
end

local function NormalizeVector(vec)
    local magnitude = vec:Length()
    if magnitude > 1e-4 then
        return Vector(vec.x / magnitude, vec.y / magnitude, vec.z / magnitude)
    else
        return Vector(0, 0, 0)
    end
end

local function NormalizeVector2D(vec)
    local magnitude = math.sqrt(vec.x^2 + vec.y^2)
    if magnitude > 1e-4 then
        return Vector2D(vec.x / magnitude, vec.y / magnitude)
    else
        return Vector2D(0, 0)
    end
end

local function CalculateAngles(from, to)
    local delta = Vector(to.x - from.x, to.y - from.y, to.z - from.z)
    local yaw = math.atan2(delta.y, delta.x) * (180 / math.pi)
    local pitch = -math.atan(delta.z / math.sqrt(delta.x^2 + delta.y^2)) * (180 / math.pi)
    return Vector(pitch, yaw, 0)
end

local function CheckSameXY(pos1, pos2, tolerance)
    tolerance = tolerance or 32 -- Default tolerance if not provided
    return math.abs(pos1.x - pos2.x) <= tolerance and math.abs(pos1.y - pos2.y) <= tolerance
end

local function GetTeammateViewYaw(teammatePawn)
    if teammatePawn.m_angEyeAngles then
        return teammatePawn.m_angEyeAngles.y
    end

    local velocity = teammatePawn.m_vecAbsVelocity or Vector(0,0,0)
    if math.sqrt(velocity.x^2 + velocity.y^2) > 10 then
        return math.atan2(velocity.y, velocity.x) * (180 / math.pi)
    end
    return 0
end

local function IsOnScreen(screenPos)
    if not screenPos or (screenPos.x == 0 and screenPos.y == 0) then return false end
    local screenSize = Renderer.GetScreenSize()
    return screenPos.x >= 0 and screenPos.x <= screenSize.x and screenPos.y >= 0 and screenPos.y <= screenSize.y
end

-- Fungsi untuk mensimulasikan pergerakan mouse
local function SendMouseMove(dx, dy)
    local input = ffi.new("INPUT")
    input.type = INPUT_MOUSE
    input.mi.dx = math.floor(dx + 0.5)
    input.mi.dy = math.floor(dy + 0.5)
    input.mi.mouseData = 0
    input.mi.dwFlags = MOUSEEVENTF_MOVE
    input.mi.time = 0
    input.mi.dwExtraInfo = 0
    ffi.C.SendInput(1, input, ffi.sizeof("INPUT"))
end

-- Fungsi untuk mensimulasikan satu kali klik kiri
local function SimulateLeftClick()
    local input_down = ffi.new("INPUT")
    input_down.type = INPUT_MOUSE
    input_down.mi.dwFlags = MOUSEEVENTF_LEFTDOWN

    local input_up = ffi.new("INPUT")
    input_up.type = INPUT_MOUSE
    input_up.mi.dwFlags = MOUSEEVENTF_LEFTUP

    ffi.C.SendInput(1, input_down, ffi.sizeof("INPUT"))
    ffi.C.SendInput(1, input_up, ffi.sizeof("INPUT"))
end

local function IsTeammateValid(teammatePawn)
    if not teammatePawn or not teammatePawn.m_pGameSceneNode then return false end
    
    local health = teammatePawn.m_iHealth or 0
    if health <= 0 then return false end
    
    if teammatePawn.m_lifeState and teammatePawn.m_lifeState ~= 0 then -- LIFE_ALIVE is 0
        return false
    end
    return true
end

local function GetEyePosition(pawn)
    if pawn and pawn.m_pGameSceneNode then
        local origin = pawn.m_pGameSceneNode.m_vecAbsOrigin
        return Vector(origin.x, origin.y, origin.z + 64)
    end
    return nil
end

local function GetLocalPlayerPawn()
    local highestIndex = Entities.GetHighestEntityIndex() or 0
    for i = 1, highestIndex do
        local entity = Entities.GetEntityFromIndex(i)
        if entity and entity.m_bIsLocalPlayerController then
            return entity.m_hPawn
        end
    end
    return nil
end

local function GetLocalPlayerPing() 
    local highest_entity_index = Entities.GetHighestEntityIndex() or 0
    for i = 1, highest_entity_index do
        local entity = Entities.GetEntityFromIndex(i)
        if entity and entity.m_bIsLocalPlayerController then
            return entity.m_iPing or 0
        end
    end
    return 0
end

local function GriefTeammateGrenade(cmd)
    if not grief_settings.grenade_griefer then return false end

    local localPlayerPawn = GetLocalPlayerPawn()
    if not localPlayerPawn or not localPlayerPawn.m_pGameSceneNode then return false end

    local screenSize = Renderer.GetScreenSize()
    if not screenSize then return false end

    local localPlayerTeam = localPlayerPawn.m_iTeamNum
    local highestIndex = Entities.GetHighestEntityIndex() or 0
    
    local targetGrenade = nil
    local closestDistToCenter = 9e9
    local fovRadius = grief_settings.fov

    for i = 1, highestIndex do
        local entity = Entities.GetEntityFromIndex(i)
        if entity and entity.m_pGameSceneNode then
            if Entities.GetDesignerName(entity) == "smokegrenade_projectile" then
                local didSmoke = entity.m_bDidSmokeEffect
                if didSmoke == false then
                    local owner = entity.m_hThrower
                    if owner and owner.m_pGameSceneNode and owner.m_iTeamNum == localPlayerTeam and owner ~= localPlayerPawn then
                        local targetPos = entity.m_pGameSceneNode.m_vecAbsOrigin
                        local screenPos = Renderer.WorldToScreen(targetPos)
                        
                        if screenPos then
                            local centerX, centerY = screenSize.x / 2, screenSize.y / 2
                            local distToCenter = math.sqrt((screenPos.x - centerX)^2 + (screenPos.y - centerY)^2)
                            
                            if distToCenter < fovRadius and distToCenter < closestDistToCenter then
                                closestDistToCenter = distToCenter
                                targetGrenade = entity
                            end
                        end
                    end
                end
            end
        end
    end

    if targetGrenade then
        local targetPos = targetGrenade.m_pGameSceneNode.m_vecAbsOrigin
        local screenPos = Renderer.WorldToScreen(targetPos)
        if screenPos then
            local centerX, centerY = screenSize.x / 2, screenSize.y / 2
            local deltaX, deltaY = screenPos.x - centerX, screenPos.y - centerY
            
            SendMouseMove(deltaX, deltaY)
            ffi.C.Sleep(1)
            SimulateLeftClick()
            return true 
        end
    end

    return false
end

function GetAllPlayerNames()
    local enemies = {}
    local teammates = {}
    local local_player_pawn = GetLocalPlayerPawn()
    if not local_player_pawn or not local_player_pawn.m_iTeamNum then return enemies, teammates end
    
    local local_team_num = local_player_pawn.m_iTeamNum
    local highestIndex = Entities.GetHighestEntityIndex() or 0

    for i = 1, highestIndex do
        local controller = Entities.GetEntityFromIndex(i)
        if controller and controller.m_sSanitizedPlayerName and not controller.m_bIsLocalPlayerController and controller.m_hPawn and controller.m_hPawn.m_iTeamNum then
            if controller.m_hPawn.m_iTeamNum == local_team_num then
                table.insert(teammates, controller.m_sSanitizedPlayerName)
            else
                table.insert(enemies, controller.m_sSanitizedPlayerName)
            end
        end
    end
    table.sort(enemies)
    table.sort(teammates)
    return enemies, teammates
end

function GetAllPlayersSortedByTeam()
    local enemies = {}
    local teammates = {}
    local local_player_pawn = GetLocalPlayerPawn()
    if not local_player_pawn then return enemies, teammates end
    
    local local_team_num = local_player_pawn.m_iTeamNum
    local highestIndex = Entities.GetHighestEntityIndex() or 0

    for i = 1, highestIndex do
        local controller = Entities.GetEntityFromIndex(i)
        if controller and controller.m_sSanitizedPlayerName and not controller.m_bIsLocalPlayerController and controller.m_hPawn then
            if controller.m_hPawn.m_iTeamNum == local_team_num then
                table.insert(teammates, controller.m_sSanitizedPlayerName)
            else
                table.insert(enemies, controller.m_sSanitizedPlayerName)
            end
        end
    end
    table.sort(enemies)
    table.sort(teammates)
    return enemies, teammates
end

local function UpdateListPageContent(player_names_list, gui_elements, page_state)
    page_state.total_pages = math.ceil(#player_names_list / page_state.items_per_page)
    if page_state.total_pages < 1 then page_state.total_pages = 1 end
    if page_state.current_page > page_state.total_pages then page_state.current_page = page_state.total_pages end

    local start_index = (page_state.current_page - 1) * page_state.items_per_page + 1

    for i = 1, page_state.items_per_page do
        local slot_item = gui_elements.slots[i]
        if slot_item then
            local player_name = player_names_list[start_index + i - 1]
            if player_name then
                slot_item.text = player_name
                slot_item.checked = player_esp_states[player_name] or false
                GUI.ShowElement(slot_item)
            else
                GUI.HideElement(slot_item)
            end
        end
    end
    
    if gui_elements.page_label then
        gui_elements.page_label.text = string.format("Page %d / %d", page_state.current_page, page_state.total_pages)
    end
end

local function SetupESPMenu()
    if gui_initialized then return end

    GUI.CreatePropperMenuLayout({
        windowTitle = "STAY MAD", x = 200, y = 200, width = 600, height = 550,
        categories = {"Enemy ESP", "Team ESP", "ESP Setting", "Griefing Setting"} 
    })

    local enemy_names, teammate_names = GetAllPlayersSortedByTeam()

    GUI.BeginCategory("ESP Enemy")
    for i = 1, enemy_page_state.items_per_page do
        local slot_index = i
        local checkbox = GUI.MenuCheckbox("...", false, function(checked)
            local current_player_name = enemy_gui_elements.slots[slot_index].text
            if current_player_name and current_player_name ~= "..." then
                player_esp_states[current_player_name] = checked
            end
        end)
        table.insert(enemy_gui_elements.slots, checkbox)
    end
    enemy_gui_elements.prev_button = GUI.MenuButton("< Before", function()
        if enemy_page_state.current_page > 1 then
            enemy_page_state.current_page = enemy_page_state.current_page - 1
            UpdateListPageContent(GetAllPlayersSortedByTeam(), enemy_gui_elements, enemy_page_state)
        end
    end)
    enemy_gui_elements.page_label = GUI.MenuLabel("Page 1 / 1")
    enemy_gui_elements.next_button = GUI.MenuButton("Next >", function()
        local current_enemies, _ = GetAllPlayersSortedByTeam()
        if enemy_page_state.current_page < math.ceil(#current_enemies / enemy_page_state.items_per_page) then
            enemy_page_state.current_page = enemy_page_state.current_page + 1
            UpdateListPageContent(current_enemies, enemy_gui_elements, enemy_page_state)
        end
    end)
    UpdateListPageContent(enemy_names, enemy_gui_elements, enemy_page_state)

    GUI.BeginCategory("ESP Team")
    for i = 1, teammate_page_state.items_per_page do
        local slot_index = i
        local checkbox = GUI.MenuCheckbox("...", false, function(checked)
            local current_player_name = teammate_gui_elements.slots[slot_index].text
            if current_player_name and current_player_name ~= "..." then
                player_esp_states[current_player_name] = checked
            end
        end)
        table.insert(teammate_gui_elements.slots, checkbox)
    end
    teammate_gui_elements.prev_button = GUI.MenuButton("< Before", function()
        if teammate_page_state.current_page > 1 then
            teammate_page_state.current_page = teammate_page_state.current_page - 1
            UpdateListPageContent(GetAllPlayersSortedByTeam(), teammate_gui_elements, teammate_page_state)
        end
    end)
    teammate_gui_elements.page_label = GUI.MenuLabel("Page 1 / 1")
    teammate_gui_elements.next_button = GUI.MenuButton("Next >", function()
        local _, current_teammates = GetAllPlayersSortedByTeam()
        if teammate_page_state.current_page < math.ceil(#current_teammates / teammate_page_state.items_per_page) then
            teammate_page_state.current_page = teammate_page_state.current_page + 1
            UpdateListPageContent(current_teammates, teammate_gui_elements, teammate_page_state)
        end
    end)
    UpdateListPageContent(teammate_names, teammate_gui_elements, teammate_page_state)
    
    GUI.BeginCategory("ESP Setting")
    GUI.MenuCheckbox("ESP Box", esp_settings.show_box, function(val) esp_settings.show_box = val end)
    GUI.MenuCheckbox("ESP Name", esp_settings.show_name, function(c) esp_settings.show_name = c end)
    GUI.MenuCheckbox("ESP Distance", esp_settings.show_distance, function(c) esp_settings.show_distance = c end)
    GUI.MenuCheckbox("ESP Health Bar", esp_settings.show_health_bar, function(c) esp_settings.show_health_bar = c end)
    GUI.MenuCheckbox("Snapline", esp_settings.show_line, function(c) esp_settings.show_line = c end)
    GUI.BeginCategory("Griefing Setting")
    GUI.MenuCheckbox("Granade Griefing", grief_settings.grenade_griefer, function(val) grief_settings.grenade_griefer = val end)
    GUI.MenuCheckbox("Weapon Stealer", grief_settings.weapon_stealer, function(val) grief_settings.weapon_stealer = val end)
    GUI.MenuCheckbox("Defuse/Plant Blocker", grief_settings.defuse_blocker, function(val) grief_settings.defuse_blocker = val end)
    GUI.MenuCheckbox("Auto Molotov Grief", grief_settings.molotov_grief, function(val) grief_settings.molotov_grief = val end)
    GUI.MenuLabel("")
    GUI.MenuSlider("Granade Griefing FOV", 1, 300, grief_settings.fov, function(val) grief_settings.fov = val end)
    GUI.MenuCheckbox("Draw FOV", grief_settings.show_fov, function(val) grief_settings.show_fov = val end)


    gui_initialized = true
end

local function DrawESPForTargets()
    if next(player_esp_states) == nil then return end

    local local_player = GetLocalPlayerPawn()
    if not local_player or not local_player.m_pGameSceneNode then return end
    
    local local_player_pos = local_player.m_pGameSceneNode.m_vecAbsOrigin
    local screen_size = Renderer.GetScreenSize() 
    if not screen_size then return end 

    local show_box = esp_settings.show_box
    local show_name = esp_settings.show_name
    local show_distance = esp_settings.show_distance
    local show_health_bar = esp_settings.show_health_bar
    local show_line = esp_settings.show_line
    
    local highestIndex = Entities.GetHighestEntityIndex() or 0

    for i = 1, highestIndex do
        local controller = Entities.GetEntityFromIndex(i)
        if controller and controller.m_sSanitizedPlayerName and player_esp_states[controller.m_sSanitizedPlayerName] then
            local pawn = controller.m_hPawn
            if pawn and pawn.m_pGameSceneNode and pawn.m_iHealth > 0 then
                local player_pos = pawn.m_pGameSceneNode.m_vecAbsOrigin
                local screen_pos = Renderer.WorldToScreen(player_pos)

                if screen_pos then
                    local text_y_offset = 0
                    
                    if show_box then
                        local head_offset = Vector(0, 0, 72)
                        local head_pos_3d = Vector(player_pos.x, player_pos.y, player_pos.z + head_offset.z)
                        local screen_head_pos = Renderer.WorldToScreen(head_pos_3d)

                        if screen_head_pos then
                            local h = screen_pos.y - screen_head_pos.y
                            local w = h / 2
                            local x = screen_pos.x - w / 2
                            
                            Renderer.DrawRect(Vector2D(x, screen_head_pos.y), Vector2D(x + w, screen_pos.y), esp_color)
                            Renderer.DrawRect(Vector2D(x-1, screen_head_pos.y-1), Vector2D(x + w + 1, screen_pos.y + 1), Color(0,0,0,255))
                            Renderer.DrawRect(Vector2D(x+1, screen_head_pos.y+1), Vector2D(x + w - 1, screen_pos.y - 1), Color(0,0,0,255))
                            
                            text_y_offset = screen_head_pos.y - 15
                        end
                    end
                    
                    if show_name or show_distance then
                        local name_text = show_name and controller.m_sSanitizedPlayerName or ""
                        local dist_text = ""
                        if show_distance then
                           local distance_val = player_pos:DistTo(local_player_pos) or 0
                           dist_text = " [" .. string.format("%.0f", distance_val / 39.37) .. "m]" -- Konversi ke meter
                        end
                        Renderer.DrawText("TahomaDebug23", name_text .. dist_text, Vector2D(screen_pos.x, text_y_offset > 0 and text_y_offset or screen_pos.y), true, true, esp_color)
                        text_y_offset = text_y_offset + 15
                    end
                    
                    if show_health_bar then
                        local h, w, x_box, y_box = 0, 0, 0, 0
                        local head_offset = Vector(0, 0, 72)
                        local head_pos_3d = Vector(player_pos.x, player_pos.y, player_pos.z + head_offset.z)
                        local screen_head_pos = Renderer.WorldToScreen(head_pos_3d)

                        if screen_head_pos then
                           h = screen_pos.y - screen_head_pos.y
                           w = h / 2
                           x_box = screen_pos.x - w / 2
                           y_box = screen_head_pos.y
                        end

                        local health = pawn.m_iHealth
                        local health_fraction = health / 100
                        local bar_height = 4
                        local bar_x = x_box
                        local bar_y = y_box + h + 2
                        
                        local health_color = Color(255 * (1 - health_fraction), 255 * health_fraction, 0, 255)
                        
                        Renderer.DrawRectFilled(Vector2D(bar_x - 1, bar_y - 1), Vector2D(bar_x + w + 1, bar_y + bar_height + 1), Color(0, 0, 0, 190))
                        Renderer.DrawRectFilled(Vector2D(bar_x, bar_y), Vector2D(bar_x + (w * health_fraction), bar_y + bar_height), health_color)
                    end
                    
                    if show_line then
                        -- Baris ini sekarang aman karena screen_size sudah didefinisikan
                        Renderer.DrawLine(Vector2D(screen_size.x / 2, screen_size.y), screen_pos, esp_color, 1)
                    end
                end
            end
        end
    end
end


local function CalculatePusherMove(cmd, localPlayerPawn, targetTeammate)

    if not localPlayerPawn or not localPlayerPawn.m_pGameSceneNode or 
       not targetTeammate or not targetTeammate.m_pGameSceneNode then
        return
    end

    local localPos = localPlayerPawn.m_pGameSceneNode.m_vecAbsOrigin
    local targetPos = targetTeammate.m_pGameSceneNode.m_vecAbsOrigin

    local desiredMoveDirection = Vector(targetPos.x - localPos.x, targetPos.y - localPos.y, 0)

    local normalizedMove = NormalizeVector(desiredMoveDirection)

    local viewYawRad = math.rad(cmd.m_angViewAngles.y)
    local cosYaw = math.cos(viewYawRad)
    local sinYaw = math.sin(viewYawRad)

    local forwardComponent = normalizedMove.x * cosYaw + normalizedMove.y * sinYaw
    local sideComponent = -normalizedMove.x * sinYaw + normalizedMove.y * cosYaw

    cmd.m_flForwardMove = forwardComponent * 450 
    cmd.m_flLeftMove = sideComponent * 450

end

local function FindBlockTeammate()
    local localPlayerControllerPawn = GetLocalPlayerPawn()
    if not localPlayerControllerPawn or not localPlayerControllerPawn.m_pGameSceneNode then
        blockEnemy = nil; currentTarget = nil
        prev_lateral_offset_sign_for_adad = 0; adad_active_timer = 0
        last_lateral_change_time = 0; adad_rhythm_streak = 0
        return
    end

    local localPlayerOrigin = localPlayerControllerPawn.m_pGameSceneNode.m_vecAbsOrigin
    local localPlayerTeam = localPlayerControllerPawn.m_iTeamNum

    -- Target stickiness: if current target is still valid and relatively close, keep them.
    if currentTarget and IsTeammateValid(currentTarget) then
        if currentTarget.m_pGameSceneNode then -- Ensure scene node exists before accessing origin
             if localPlayerOrigin:DistTo(currentTarget.m_pGameSceneNode.m_vecAbsOrigin) < 1000 then
                blockEnemy = currentTarget
                return
             end
        end
    end
    
    -- Reset current target and search for a new one
    currentTarget = nil
    local closestDistance = math.huge
    local bestTeammatePawn = nil
    local highestIndex = Entities.GetHighestEntityIndex() or 0

    for i = 1, highestIndex do
        local entity = Entities.GetEntityFromIndex(i)
        if entity and entity.m_bIsLocalPlayerController ~= nil and not entity.m_bIsLocalPlayerController and entity.m_hPawn then
            local potentialTeammatePawn = entity.m_hPawn
            if potentialTeammatePawn and potentialTeammatePawn.m_iTeamNum == localPlayerTeam and potentialTeammatePawn ~= localPlayerControllerPawn then
                if IsTeammateValid(potentialTeammatePawn) and potentialTeammatePawn.m_pGameSceneNode then
                    local teammateOrigin = potentialTeammatePawn.m_pGameSceneNode.m_vecAbsOrigin
                    local distanceToTeammate = localPlayerOrigin:DistTo(teammateOrigin)
                    
                    -- Consider a teammate if they are close enough and closer than the current best
                    if distanceToTeammate > 1 and distanceToTeammate < 800 and distanceToTeammate < closestDistance then
                        closestDistance = distanceToTeammate
                        bestTeammatePawn = potentialTeammatePawn
                    end
                end
            end
        end
    end

    blockEnemy = bestTeammatePawn
    currentTarget = bestTeammatePawn -- Set for stickiness next frame

    if not blockEnemy then -- If no target found, reset ADAD state
        prev_lateral_offset_sign_for_adad = 0
        adad_active_timer = 0
        last_lateral_change_time = 0; adad_rhythm_streak = 0
    end
end

local function FindDefusingOrPlantingTeammate()
    local localPlayerPawn = GetLocalPlayerPawn()
    if not localPlayerPawn then return nil end

    local localPlayerTeam = localPlayerPawn.m_iTeamNum
    local highestIndex = Entities.GetHighestEntityIndex() or 0

    for i = 1, highestIndex do
        if entity and entity.m_bIsLocalPlayerController ~= nil and not entity.m_bIsLocalPlayerController and entity.m_hPawn then
            local potentialTarget = entity.m_hPawn
            if potentialTarget and potentialTarget.m_iTeamNum == localPlayerTeam then
                if potentialTarget.m_bIsDefusing or potentialTarget.m_bIsPlanting then
                    return potentialTarget
                end
            end
        end
    end
    return nil
end

local function FindTeammateMolotovFire()
    local localPlayerPawn = GetLocalPlayerPawn()
    if not localPlayerPawn then return nil end

    local localPlayerTeam = localPlayerPawn.m_iTeamNum
    local highestIndex = Entities.GetHighestEntityIndex() or 0

    for i = 1, highestIndex do
        local entity = Entities.GetEntityFromIndex(i)

        if entity and entity.m_pGameSceneNode then

            if Entities.GetDesignerName(entity) == "inferno" then

                local owner = entity.m_hOwnerEntity

                if owner and owner.m_pGameSceneNode then
                
                    if owner.m_iTeamNum == localPlayerTeam and owner ~= localPlayerPawn then
                        return entity.m_pGameSceneNode.m_vecAbsOrigin
                    end
                end
            end
        end
    end

    return nil
end

local function FindWeaponToSteal()
    local localPlayerPawn = GetLocalPlayerPawn()
    if not localPlayerPawn or not localPlayerPawn.m_pGameSceneNode then return nil end

    -- Daftar senjata
    local valuable_weapons = {
        ["weapon_awp"] = true,
        ["weapon_ak47"] = true,
        ["weapon_m4a1"] = true, -- M4A4
        ["weapon_m4a1_silencer"] = true -- M4A1-S
    }

    local localPos = localPlayerPawn.m_pGameSceneNode.m_vecAbsOrigin
    local localPlayerTeam = localPlayerPawn.m_iTeamNum
    local highestIndex = Entities.GetHighestEntityIndex() or 0

    for i = 1, highestIndex do
        local weapon_entity = Entities.GetEntityFromIndex(i)

        if weapon_entity and weapon_entity.m_pGameSceneNode and valuable_weapons[Entities.GetDesignerName(weapon_entity)] then
            
            local last_owner = weapon_entity.m_hOwnerEntity

            if last_owner and last_owner.m_pGameSceneNode and last_owner.m_iTeamNum == localPlayerTeam then

                local weaponPos = weapon_entity.m_pGameSceneNode.m_vecAbsOrigin
                
                -- Pastikan senjata tidak terlalu jauh untuk efisiensi
                if localPos:DistTo(weaponPos) < 2000 then -- Jarak maksimal 2000 unit
                    return weaponPos -- Kembalikan posisi senjata sebagai target
                end
            end
        end
    end

    return nil -- Tidak ada senjata teman yang layak untuk dicuri
end

local function BlockbotLogic(cmd)
    if not cmd then return end

        if Globals.IsConnected() and GriefTeammateGrenade(cmd) then
        return 
    end

    if weapon_stealer_enable:GetBool() and Globals.IsConnected() then
        local weapon_position = FindWeaponToSteal()
        if weapon_position then
            local localPlayerForGrief = GetLocalPlayerPawn()
            if localPlayerForGrief then
                local dummy_target = { m_pGameSceneNode = { m_vecAbsOrigin = weapon_position } }
                CalculatePusherMove(cmd, localPlayerForGrief, dummy_target)
                return 
            end
        end
    end

    if auto_molotov_grief_enable:GetBool() and Globals.IsConnected() then
        local fire_position = FindTeammateMolotovFire()
        if fire_position then
            local localPlayerForGrief = GetLocalPlayerPawn()
            if localPlayerForGrief then   
                local dummy_target = {
                    m_pGameSceneNode = {
                        m_vecAbsOrigin = fire_position
                    }
                }
                CalculatePusherMove(cmd, localPlayerForGrief, dummy_target)
                return
            end
        end
    end

    if defuse_plant_blocker_enable:GetBool() and Globals.IsConnected() then
        local griefingTarget = FindDefusingOrPlantingTeammate()
        if griefingTarget then
            local localPlayerForGrief = GetLocalPlayerPawn()
            if localPlayerForGrief then
                CalculatePusherMove(cmd, localPlayerForGrief, griefingTarget)
                return 
            end
        end
    end

    local localPlayerPawn = GetLocalPlayerPawn()
    local local_ping = GetLocalPlayerPing()

    -- Convert ping to seconds for prediction offset
    local ping_offset_seconds = local_ping / 1000.0

    -- Calculate actual frametime for prediction, with a safe default
    local actualFrameTime = Globals.GetFrameTime() or 0.015625
    if actualFrameTime <= 0 then actualFrameTime = 0.015625 end -- Ensure positive frametime
    local predictionFrameTime = math.min(actualFrameTime, MAX_PREDICTION_FRAMETIME) -- Cap frametime for prediction

    -- Handle local player state (on ground, jump commands)
    local is_on_ground_this_frame = true
    if localPlayerPawn and localPlayerPawn.m_pGameSceneNode then
        if localPlayerPawn.m_fFlags ~= nil then
            is_on_ground_this_frame = bit.band(localPlayerPawn.m_fFlags, 1) ~= 0 -- FL_ONGROUND
        end
        if bot_has_active_jump_command and is_on_ground_this_frame then
            CVar.ExecuteClientCmd("-jump")
            bot_has_active_jump_command = false
        end
    else
        if bot_has_active_jump_command then CVar.ExecuteClientCmd("-jump"); bot_has_active_jump_command = false end
        blockEnemy = nil; currentTarget = nil
        prev_lateral_offset_sign_for_adad = 0; adad_active_timer = 0
        last_lateral_change_time = 0; adad_rhythm_streak = 0
        return
    end

    if not blockbot_enable:GetBool() or not blockbot_enable:IsDown() then
        if bot_has_active_jump_command then CVar.ExecuteClientCmd("-jump"); bot_has_active_jump_command = false end
        blockEnemy = nil; currentTarget = nil
        prev_lateral_offset_sign_for_adad = 0; adad_active_timer = 0
        last_lateral_change_time = 0; adad_rhythm_streak = 0
        return
    end

    if not Globals.IsConnected() then return end

    FindBlockTeammate()

    local accel_x, accel_y = 0, 0

    if not blockEnemy or not blockEnemy.m_pGameSceneNode or not IsTeammateValid(blockEnemy) then
        if bot_has_active_jump_command then CVar.ExecuteClientCmd("-jump"); bot_has_active_jump_command = false end
        blockEnemy = nil; currentTarget = nil;
        prev_block_enemy_ref_for_accel = nil
        prev_target_pos_for_accel = nil
        prev_target_vel_for_accel = nil
        prev_lateral_offset_sign_for_adad = 0
        adad_active_timer = 0
        last_lateral_change_time = 0; adad_rhythm_streak = 0
        return
    end

    local teammate_ping = blockEnemy.m_iPing or 0
    local teammate_ping_offset_seconds = teammate_ping / 1000.0
    local localPos = localPlayerPawn.m_pGameSceneNode.m_vecAbsOrigin
    local teammatePos = blockEnemy.m_pGameSceneNode.m_vecAbsOrigin
    local teammateVel = blockEnemy.m_vecAbsVelocity or Vector(0,0,0)
    local teammateSpeedXY = math.sqrt(teammateVel.x^2 + teammateVel.y^2)
    
    if prev_block_enemy_ref_for_accel ~= blockEnemy or not prev_target_pos_for_accel or not prev_target_vel_for_accel then
        prev_target_pos_for_accel = Vector(teammatePos.x, teammatePos.y, teammatePos.z)
        prev_target_vel_for_accel = Vector(teammateVel.x, teammateVel.y, teammateVel.z)
        prev_actual_frame_time_for_accel_calc = actualFrameTime 
        prev_block_enemy_ref_for_accel = blockEnemy
    else
        if prev_actual_frame_time_for_accel_calc > VIEW_ANGLES_MIN_VALID_PREV_FRAME_TIME then
            local delta_vx = teammateVel.x - prev_target_vel_for_accel.x
            local delta_vy = teammateVel.y - prev_target_vel_for_accel.y
            accel_x = delta_vx / prev_actual_frame_time_for_accel_calc
            accel_y = delta_vy / prev_actual_frame_time_for_accel_calc
            accel_x = accel_x * VIEW_ANGLES_ACCEL_DAMPING_FACTOR
            accel_y = accel_y * VIEW_ANGLES_ACCEL_DAMPING_FACTOR
        end
        prev_target_pos_for_accel = Vector(teammatePos.x, teammatePos.y, teammatePos.z)
        prev_target_vel_for_accel = Vector(teammateVel.x, teammateVel.y, teammateVel.z)
        prev_actual_frame_time_for_accel_calc = actualFrameTime
    end
    
    local isOnHead = (localPos.z - teammatePos.z) > ON_HEAD_Z_THRESHOLD and 
                     CheckSameXY(localPos, teammatePos, ON_HEAD_XY_TOLERANCE)

    if autojump_enable:GetBool() and not isOnHead and 
       math.abs(teammateVel.z) > AUTOJUMP_TARGET_Z_VEL_THRESHOLD and 
       is_on_ground_this_frame and not bot_has_active_jump_command then
        CVar.ExecuteClientCmd("+jump")
        bot_has_active_jump_command = true
    end

    if adad_active_timer > 0 then
        adad_active_timer = adad_active_timer - actualFrameTime
        if adad_active_timer < 0 then adad_active_timer = 0 end
    end
    local is_adad_currently_active = adad_active_timer > 0

    if isOnHead then
        local predictionFrameTime = Globals.GetFrameTime()
        local predictedTeammatePos = Vector(
            teammatePos.x + teammateVel.x * predictionFrameTime * 5,
            teammatePos.y + teammateVel.y * predictionFrameTime * 5, 
            teammatePos.z
        )
        local correction_target_pos = Vector(predictedTeammatePos.x, predictedTeammatePos.y, predictedTeammatePos.z + ON_HEAD_HEIGHT_OFFSET)
        
        local correction_vector = Vector(correction_target_pos.x - localPos.x, correction_target_pos.y - localPos.y, 0)
        local correction_distance = correction_vector:Length()

        local ourViewRadians = math.rad(cmd.m_angViewAngles.y)
        local cos_yaw = math.cos(ourViewRadians)
        local sin_yaw = math.sin(ourViewRadians)

        local vel_match_forward = (teammateVel.x * cos_yaw + teammateVel.y * sin_yaw) / MAX_PLAYER_SPEED
        local vel_match_side = (-teammateVel.x * sin_yaw + teammateVel.y * cos_yaw) / MAX_PLAYER_SPEED
        
        local correction_forward = 0
        local correction_side = 0
        local correction_gain = 0.05

        if correction_distance > 1.0 then
            local normalized_correction = NormalizeVector(correction_vector)
            correction_forward = (normalized_correction.x * cos_yaw + normalized_correction.y * sin_yaw) * correction_distance * correction_gain
            correction_side = (-normalized_correction.x * sin_yaw + normalized_correction.y * cos_yaw) * correction_distance * correction_gain
        end

        local finalForwardMove = vel_match_forward + correction_forward
        local finalSideMove = vel_match_side + correction_side

        cmd.m_flForwardMove = math.max(-1.0, math.min(1.0, finalForwardMove))
        cmd.m_flLeftMove = math.max(-1.0, math.min(1.0, finalSideMove))
    else 
        --// GROUND LOGIC //--
        local selectedMode = blocking_mode_combo:GetInt()

        if selectedMode == 0 then -- View Angles Mode
            cmd.m_flLeftMove = 0.0
            
            -- Adaptive Prediction: Adjust prediction frames based on target speed (when not in ADAD mode)
            local speed_factor = math.max(0, math.min(1, teammateSpeedXY / MAX_PLAYER_SPEED)) -- Normalize speed 0-1
            local dynamic_pred_frames_base = VIEW_ANGLES_PREDICTION_FRAMES_ACCEL_BASE_MIN + 
                                             (VIEW_ANGLES_PREDICTION_FRAMES_ACCEL_BASE_MAX - VIEW_ANGLES_PREDICTION_FRAMES_ACCEL_BASE_MIN) * speed_factor
            
            local current_prediction_frames_accel = dynamic_pred_frames_base
            if is_adad_currently_active then
                current_prediction_frames_accel = VIEW_ANGLES_PREDICTION_FRAMES_ACCEL_ADAD -- Override with ADAD specific short prediction
            end
            
            -- Calculate predicted target position using velocity and acceleration
            -- Add both local and teammate ping to prediction time
            local pred_time_seconds = (predictionFrameTime * current_prediction_frames_accel) + ping_offset_seconds + teammate_ping_offset_seconds
            
            local predicted_x = teammatePos.x + (teammateVel.x * pred_time_seconds) + (0.5 * accel_x * pred_time_seconds^2)
            local predicted_y = teammatePos.y + (teammateVel.y * pred_time_seconds) + (0.5 * accel_y * pred_time_seconds^2)
            local targetPosForLateralCalc = Vector(predicted_x, predicted_y, teammatePos.z)
            
            -- Calculate lateral offset: how far left/right the target is relative to our facing direction
            local vectorToTarget = Vector(targetPosForLateralCalc.x - localPos.x, targetPosForLateralCalc.y - localPos.y, 0)
            local currentYawRad = math.rad(cmd.m_angViewAngles.y)
            local localRightVectorX = math.sin(currentYawRad)
            local localRightVectorY = -math.cos(currentYawRad)
            local lateralOffset = vectorToTarget.x * localRightVectorX + vectorToTarget.y * localRightVectorY

            -- ADAD Detection Logic: Check for reversals in lateral movement
            local current_lateral_offset_sign = 0
            if math.abs(lateralOffset) > ADAD_MIN_LATERAL_OFFSET_FOR_SIGN then
                 current_lateral_offset_sign = lateralOffset > 0 and 1 or -1 -- 1 for right, -1 for left
            end

            local current_time = Globals.GetCurrentTime() or 0

            if teammateSpeedXY > ADAD_DETECTION_MIN_SPEED_XY and
               current_lateral_offset_sign ~= 0 and
               prev_lateral_offset_sign_for_adad ~= 0 and
               current_lateral_offset_sign ~= prev_lateral_offset_sign_for_adad then -- Sign must have changed (reversal)
                
                local time_since_last_change = current_time - last_lateral_change_time
                if time_since_last_change > 0 and time_since_last_change <= ADAD_RHYTHM_WINDOW_SECONDS then
                    adad_rhythm_streak = adad_rhythm_streak + 1
                else
                    adad_rhythm_streak = 1 -- Reset streak if rhythm is broken or first reversal
                end
                last_lateral_change_time = current_time -- Update last change time

                if adad_rhythm_streak >= ADAD_MIN_RHYTHM_COUNT then
                    adad_active_timer = ADAD_COUNTER_DURATION_SECONDS -- Activate/Refresh ADAD countermeasures
                    is_adad_currently_active = true                   -- Update for this frame's logic
                end
            else
                -- If no reversal or conditions not met, reset streak
                adad_rhythm_streak = 0
                last_lateral_change_time = current_time -- Keep updating for future checks
            end
            prev_lateral_offset_sign_for_adad = current_lateral_offset_sign -- Store for next frame's comparison

            -- Apply Dynamic Deadzone and Strafe Power based on ADAD state
            local effective_deadzone = VIEW_ANGLES_LATERAL_OFFSET_DEADZONE_BASE
            local effective_strafe_power = VIEW_ANGLES_MAX_STRAFE_POWER_BASE
            if is_adad_currently_active then
                effective_deadzone = VIEW_ANGLES_LATERAL_OFFSET_DEADZONE_ADAD
                effective_strafe_power = VIEW_ANGLES_MAX_STRAFE_POWER_ADAD
            end
            
            -- Apply strafe movement if outside the deadzone
            if math.abs(lateralOffset) > effective_deadzone then
                if lateralOffset > 0 then 
                    cmd.m_flLeftMove = -effective_strafe_power -- Target is to our right, so we move left
                else 
                    cmd.m_flLeftMove = effective_strafe_power  -- Target is to our left, so we move right
                end
            end
        elseif selectedMode == 1 then -- Front Block Mode
            prev_lateral_offset_sign_for_adad = 0 
            adad_active_timer = 0
            last_lateral_change_time = 0; adad_rhythm_streak = 0
            is_adad_currently_active = false
            
            local targetForwardAngleDegreesFB = GetTeammateViewYaw(blockEnemy)

            local predictionFrameTime = Globals.GetFrameTime() or 0.015625
            local predFramesFB = FRONT_BLOCK_PREDICTION_FRAMES
            local total_pred_time_fb = (predictionFrameTime * predFramesFB)
            local predTargetPosFB = Vector(
                teammatePos.x + teammateVel.x * total_pred_time_fb,
                teammatePos.y + teammateVel.y * total_pred_time_fb,
                teammatePos.z
            )
            
            local angleRadiansFB = math.rad(targetForwardAngleDegreesFB)
            local blockPositionFB = Vector(
                predTargetPosFB.x + math.cos(angleRadiansFB) * FRONT_BLOCK_DISTANCE, 
                predTargetPosFB.y + math.sin(angleRadiansFB) * FRONT_BLOCK_DISTANCE, 
                predTargetPosFB.z + FRONT_BLOCK_HEIGHT_OFFSET
            )
            
            local neededMoveFB = Vector(blockPositionFB.x - localPos.x, blockPositionFB.y - localPos.y, 0)
            local distToTargetXY_FB = math.sqrt(neededMoveFB.x^2 + neededMoveFB.y^2)
            
            local fwdMoveFB, leftMoveFB = 0.0, 0.0
            if distToTargetXY_FB > FRONT_BLOCK_DEADZONE_HORIZONTAL then
                local corrTimeFB = predictionFrameTime * math.max(0.001, FRONT_BLOCK_CORRECTION_TIMESCALE_FRAMES)
                if corrTimeFB <= 1e-5 then corrTimeFB = 1e-5 end
                
                local speedGapCloseFB = (distToTargetXY_FB / corrTimeFB) * FRONT_BLOCK_CORRECTION_GAIN
                local desiredSpeedFB = math.min(teammateSpeedXY + speedGapCloseFB, MAX_PLAYER_SPEED)
                
                local normMoveFB = NormalizeVector(neededMoveFB)
                local viewRadFB = math.rad(cmd.m_angViewAngles.y)
                local cosY_fb, sinY_fb = math.cos(viewRadFB), math.sin(viewRadFB)
                
                local moveScaleFB = 0
                if MAX_PLAYER_SPEED > 0.001 then moveScaleFB = desiredSpeedFB / MAX_PLAYER_SPEED end
                
                fwdMoveFB = (normMoveFB.x * cosY_fb + normMoveFB.y * sinY_fb) * moveScaleFB
                leftMoveFB = (-normMoveFB.x * sinY_fb + normMoveFB.y * cosY_fb) * moveScaleFB
            end
            cmd.m_flForwardMove = math.max(-1, math.min(1, fwdMoveFB))
            cmd.m_flLeftMove = math.max(-1, math.min(1, leftMoveFB))
        elseif selectedMode == 2 then
            CalculatePusherMove(cmd, localPlayerPawn, blockEnemy)
        end
    end
end

local function DrawPlayerIndicators()
    if not blockbot_enable:GetBool() or not blockbot_enable:IsDown() then return end
    if not blockEnemy or not blockEnemy.m_pGameSceneNode then return end

    local teammatePosRaw = blockEnemy.m_pGameSceneNode.m_vecAbsOrigin
    local teammateVel = blockEnemy.m_vecAbsVelocity or Vector(0,0,0)

    local actualFrameTime = Globals.GetFrameTime() or 0.015625
    if actualFrameTime <= 0 then actualFrameTime = 0.015625 end
    local predFrameTimeForVisuals = math.min(actualFrameTime, MAX_PREDICTION_FRAMETIME)
    
    local visualPredictionFrames = 4 -- How many frames ahead to predict for the visual indicator
    local predictedTeammateVisualPos = Vector(
        teammatePosRaw.x + teammateVel.x * predFrameTimeForVisuals * visualPredictionFrames, 
        teammatePosRaw.y + teammateVel.y * predFrameTimeForVisuals * visualPredictionFrames, 
        teammatePosRaw.z + teammateVel.z * predFrameTimeForVisuals * visualPredictionFrames
    )

    -- Interpolate visual position for smoothness
    local interpolatedPos
    if lastDrawnTeammatePos then
        interpolatedPos = Vector(
            lastDrawnTeammatePos.x + (predictedTeammateVisualPos.x - lastDrawnTeammatePos.x) * INTERPOLATION_ALPHA,
            lastDrawnTeammatePos.y + (predictedTeammateVisualPos.y - lastDrawnTeammatePos.y) * INTERPOLATION_ALPHA,
            lastDrawnTeammatePos.z + (predictedTeammateVisualPos.z - lastDrawnTeammatePos.z) * INTERPOLATION_ALPHA
        )
    else
        interpolatedPos = predictedTeammateVisualPos
    end
    lastDrawnTeammatePos = interpolatedPos -- Store for next frame's interpolation

    -- Get screen positions for drawing
    local screenPosTargetFeet = Renderer.WorldToScreen(interpolatedPos)

    if not IsOnScreen(screenPosTargetFeet) then return end

    -- Define colors based on menu settings or defaults
    local baseCircleColor = circle_color:GetBool() and circle_color:GetColor() or Color(0, 255, 255, 255) -- Cyan
    local onHeadCircleColor = on_head_color:GetBool() and on_head_color:GetColor() or Color(255, 255, 0, 255) -- Yellow
    
    local localPlayerPawnForDraw = GetLocalPlayerPawn()
    if not localPlayerPawnForDraw or not localPlayerPawnForDraw.m_pGameSceneNode then return end
    
    local localPlayerPosForDraw = localPlayerPawnForDraw.m_pGameSceneNode.m_vecAbsOrigin
    local currentTargetPosForDraw = blockEnemy.m_pGameSceneNode.m_vecAbsOrigin
    
    local isPlayerOnHeadForDraw = (localPlayerPosForDraw.z - currentTargetPosForDraw.z) > ON_HEAD_Z_THRESHOLD and 
                                  CheckSameXY(localPlayerPosForDraw, currentTargetPosForDraw, ON_HEAD_XY_TOLERANCE)

    -- Draw main circle around target
    if IsOnScreen(screenPosTargetFeet) then
        if isPlayerOnHeadForDraw then
            Renderer.DrawCircleGradient3D(interpolatedPos, onHeadCircleColor, Color(onHeadCircleColor.r, onHeadCircleColor.g, onHeadCircleColor.b, 100), 25)
            Renderer.DrawCircle3D(interpolatedPos, onHeadCircleColor, 35)
        else
            Renderer.DrawCircleGradient3D(interpolatedPos, baseCircleColor, Color(baseCircleColor.r, baseCircleColor.g, baseCircleColor.b, 50), 20)
            animated_circle_phase = animated_circle_phase + (Globals.GetFrameTime() * ANIMATED_CIRCLE_SPEED)
            if animated_circle_phase > math.pi * 2 then
                animated_circle_phase = animated_circle_phase - (math.pi * 2)
            end
            local z_offset_animated_circle = ANIMATED_CIRCLE_BASE_Z_OFFSET + 
                                             (math.sin(animated_circle_phase) * 0.5 + 0.5) * ANIMATED_CIRCLE_HEIGHT_RANGE
            local animatedCirclePos = Vector(interpolatedPos.x, interpolatedPos.y, interpolatedPos.z + z_offset_animated_circle)
            Renderer.DrawCircle3D(animatedCirclePos, baseCircleColor, ANIMATED_CIRCLE_RADIUS)
        end
    end

    if not isPlayerOnHeadForDraw then
        local localPlayerScreenPos = Renderer.WorldToScreen(localPlayerPosForDraw)
        if IsOnScreen(localPlayerScreenPos) and IsOnScreen(screenPosTargetFeet) then
            Renderer.DrawLine(localPlayerScreenPos, screenPosTargetFeet, Color(baseCircleColor.r, baseCircleColor.g, baseCircleColor.b, 100), 2)
        end
    end
end

local function MasterRenderLoop()
    if Input.IsMenuOpen() then
        if not gui_initialized then
            SetupESPMenu()
        end
        GUI.Render()
    end
    DrawESPForTargets()
    DrawPlayerIndicators()
    DrawGriefFOV() 
end

Cheat.RegisterCallback("OnRenderer", MasterRenderLoop)
Cheat.RegisterCallback("OnPreCreateMove", function(cmd) BlockbotLogic(cmd) end)