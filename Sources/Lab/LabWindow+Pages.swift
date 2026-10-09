import Cocoa
import SceneKit

extension LabWindowController {
    func addPopupItems(_ popup: NSPopUpButton, _ items: [(String, String)]) {
        popup.removeAllItems()
        for (title, value) in items {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = value
        }
    }

    func selectedValue(_ popup: NSPopUpButton, fallback: String) -> String {
        (popup.selectedItem?.representedObject as? String) ?? fallback
    }

    func selectPopupValue(_ popup: NSPopUpButton, _ value: String) {
        if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == value }) {
            popup.select(item)
        }
    }

    func button(_ title: String, _ selector: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: selector)
        b.bezelStyle = .rounded
        return b
    }

    private func presetButton(_ title: String, _ preset: String) -> NSButton {
        let b = button(title, #selector(presetSelected(_:)))
        b.identifier = NSUserInterfaceItemIdentifier(preset)
        return b
    }

    func section(_ title: String, kind: LabInterventionKind? = nil,
                         help: String? = nil, _ content: [NSView]) -> NSView {
        LabInspectorSection(title, kind: kind, help: help, content)
    }

    func worldPage() -> NSViewController {
        objectID.placeholderString = L("auto", "자동")
        constrainSize(objectID, width: 120)
        _ = LabForm.status(worldObjectStatusLabel)
        _ = LabForm.status(worldCapacityLabel, mono: true)
        _ = LabForm.status(playerInputStatusLabel)
        configurePlayerKeyPopups()
        configureLookSensitivitySlider()
        _ = LabForm.status(toyTargetLabel)
        _ = LabForm.status(objectListLabel, mono: true)
        _ = LabForm.status(gunStatusLabel)
        [objectX, objectY, objectZ, objectSize, objectSpeed, objectEndDistance,
         driveSpeed, driveDistance].forEach { _ = LabForm.number($0) }
        driveButton = button(L("Drive", "주행"), #selector(driveSelectedCar))
        rearmButton = button(L("Re-arm", "다시 설치"), #selector(rearmSelectedTrap))
        driveButton?.isEnabled = false   // enabled per shape by refreshToyInspector
        rearmButton?.isEnabled = false
        addPopupItems(objectShape, [(L("Box", "상자"), "box"), (L("Sphere", "공"), "sphere"), (L("Wall", "벽"), "wall"),
                                    (L("Ramp (fly can climb it)", "경사로 (파리가 오를 수 있음)"), "ramp"),
                                    (L("Food / odor source", "먹이 (냄새가 나는 곳)"), "food"),
                                    (L("Toy car", "장난감 자동차"), "car"),
                                    (L("Cage trap", "유리 함정"), "trap")])
        objectShape.target = self
        objectShape.action = #selector(objectShapeChanged)
        createOnArenaClick.title = L("Create on map click", "지도를 클릭하면 바로 만들기")
        createOnArenaClick.state = .off
        arenaPlacement.translatesAutoresizingMaskIntoConstraints = false
        constrainSize(arenaPlacement, height: 250)
        arenaPlacement.selectedShape = selectedValue(objectShape, fallback: "box")
        arenaPlacement.selectedPoint = (d(objectX), d(objectY))
        saveSceneButton = button(L("Save scene…", "장면 저장…"), #selector(saveScene))
        loadSceneButton = button(L("Load scene…", "장면 불러오기…"), #selector(loadScene))
        return LabInspectorPage([
            section(L("Selection", "선택한 대상"), help: L("Click the fly or an object in the 3D view. A selection is confirmed only by the backend's ray pick; the fly is drawn as a position marker, not its real body geometry.", "3D 화면에서 파리나 물체를 클릭하면 선택됩니다. 드래그하면 카메라가 돌아가고, Shift나 Option을 누른 채 드래그하면 옮겨지며, 스크롤이나 핀치로 확대합니다. 선택은 시뮬레이터가 실제로 맞았는지 확인한 뒤에 확정됩니다."),
                    [viewStateLabel]),
            section(L("Scene files", "장면 파일"), help: L("Saves objects and environment settings. Pause before loading; body and neuron state continue from the current time.", "물체와 환경 설정을 저장합니다. 불러오기 전에 일시정지하세요. 몸과 뉴런 상태는 현재 시점에서 이어집니다."),
                    [LabForm.buttons([saveSceneButton!, loadSceneButton!]), sceneStatus]),
            section(L("Selected object editor", "선택 물체 편집"), kind: .physical, [worldEditor]),
            section(L("Place objects", "물체 놓기"), kind: .physical,
                    help: L("Top-down map of the arena: up is +X (forward), left is +Y. Clicking the map fills X/Y; with “Create on map click” on, the click also creates the object.", "경기장을 위에서 본 지도입니다. 위쪽이 앞(+X), 왼쪽이 +Y입니다. 지도를 클릭하면 X/Y 칸이 채워지고, ‘지도를 클릭하면 바로 만들기’를 켜 두면 클릭과 동시에 물체가 생깁니다."),
                    [LabForm.grid([(L("Type", "종류"), objectShape), (L("Name", "이름"), objectID)]),
                     arenaPlacement, createOnArenaClick,
                     LabForm.grid([("X (mm)", objectX), ("Y (mm)", objectY),
                                   ("Z (mm)", objectZ), (L("Size (mm)", "크기 (mm)"), objectSize)]),
                     LabForm.buttons([button(L("Create", "만들기"), #selector(createObject)),
                                      button(L("Move", "옮기기"), #selector(moveObject)),
                                      button(L("Resize", "크기 바꾸기"), #selector(resizeObject)),
                                      button(L("Remove", "지우기"), #selector(deleteObject))]),
                     worldObjectStatusLabel, worldCapacityLabel, objectListLabel]),
            section(L("Toys", "장난감"), kind: .physical,
                    help: L("Acts on the object named above. Drive moves a toy car straight ahead along its heading; it stops at the distance, at the lawn edge, or on contact. Re-arm lifts a cage trap again; an armed trap drops when the fly walks under it. These are physical MuJoCo events only.", "위 ‘이름’ 칸의 물체에 적용됩니다. ‘주행’은 장난감 자동차를 앞쪽으로 곧게 움직이며, 정한 거리·잔디밭 가장자리·부딪힘에서 멈춥니다. ‘다시 설치’는 유리 함정을 다시 들어 올립니다. 설치된 함정은 파리가 아래로 들어오면 떨어집니다. 모두 물리 시뮬레이터의 물리 사건일 뿐입니다."),
                    [toyTargetLabel,
                     LabForm.grid([(L("Speed (mm/s)", "속도 (mm/s)"), driveSpeed), (L("Distance (mm)", "거리 (mm)"), driveDistance)]),
                     LabForm.buttons([driveButton, rearmButton].compactMap { $0 })]),
            section(L("Approach the fly", "물체를 파리에게 다가가게 하기"), kind: .physical,
                    help: L("Moves the named object toward the fly. The fly is never commanded; any response comes from the model.", "이름을 적은 물체를 파리 쪽으로 움직입니다. 파리에게 직접 명령하지 않습니다. 파리가 보이는 반응은 모두 뇌·몸 모델이 스스로 만든 것입니다."),
                    [LabForm.grid([(L("Speed (mm/s)", "속도 (mm/s)"), objectSpeed), (L("Stop at (mm)", "멈출 거리 (mm)"), objectEndDistance)]),
                     LabForm.buttons([button(L("Start approach", "다가가기 시작"), #selector(approachObject))], columns: 1)]),
            section(L("Participate", "참여"), kind: .physical,
                    help: L("Choose Participate, then click the 3D view to capture. Aim with the center mark and press E (or click) once to grab an object; press again to place it. G equips the toy BB gun; while it is equipped, F or a click fires along the view direction. WASD moves, the mouse looks, Esc releases capture. Text fields do not trigger interaction.", "‘참여’를 고르고 3D 화면을 클릭해 조작을 시작하세요. 중앙 조준점으로 물체를 겨누고 E(또는 클릭)를 한 번 누르면 집고, 다시 누르면 놓습니다. G는 장난감 비비탄총을 들고 내리며, 총을 든 동안 F나 클릭으로 보는 방향으로 발사합니다. WASD로 이동하고 마우스로 둘러봅니다. Esc는 조작을 해제합니다. 입력 칸에서는 상호작용하지 않습니다."),
                    [LabForm.grid([(L("Forward", "앞으로"), playerKeys[.forward]!), (L("Backward", "뒤로"), playerKeys[.backward]!),
                                   (L("Left", "왼쪽"), playerKeys[.left]!), (L("Right", "오른쪽"), playerKeys[.right]!),
                                   (L("Interact", "상호작용"), playerKeys[.interact]!),
                                   (L("BB gun", "비비탄총"), playerKeys[.gun]!), (L("Fire", "발사"), playerKeys[.fire]!),
                                   (L("Release", "해제"), LabForm.note(L("Esc (fixed)", "Esc (고정)"))),
                                   (L("Look sensitivity", "시점 감도"), lookSensitivitySlider)]),
                     playerInputStatusLabel, interactionStatusLabel, gunStatusLabel]),
            section(L("Reset", "초기화"), help: L("Use the smallest reset you need. Everything clears world, body, brain state, modeled stimuli, eye covers and graphs.", "필요한 부분만 초기화하세요. ‘전부’는 세계, 몸, 뇌 상태, 자극, 눈 가리개, 그래프를 모두 처음으로 되돌립니다."),
                    [LabForm.buttons([button(L("World", "세계"), #selector(resetWorld)),
                                      button(L("Body", "몸"), #selector(resetBody)),
                                      button(L("Brain", "뇌"), #selector(resetBrain)),
                                      button(L("Everything", "전부"), #selector(resetAll))])])
        ])
    }

    func sensesPage() -> NSViewController {
        [windDuration, touchStrength, touchDuration, flashIntensity, flashDuration].forEach { _ = LabForm.number($0) }
        let panel = environmentPanel
        panel.configure()
        panel.windOffButton.target = self
        panel.windOffButton.action = #selector(stopWind)
        panel.onSubmit = { [weak self] command, captured in self?.sendEdit(command, captured: captured) }
        panel.onLocalTemperature = { [weak self] celsius, mode in
            guard let self else { return }
            self.coordinator.labSetTemperature(celsius: celsius, modeledPhysiology: mode == "modeled_physiology",
                                               flywireSensory: mode == "flywire_sensory")
            self.recorder.mark(kind: mode == "environment_only" ? "environment_record_only" : "sensory_model",
                               detail: "temperature_c=\(celsius) mode=\(mode) local")
        }
        addPopupItems(touchTarget, [
            (L("Thorax", "가슴 (흉부)"), "thorax"), (L("Head", "머리"), "head"), (L("Abdomen", "배"), "abdomen"),
            (L("Left front leg", "왼쪽 앞다리"), "left_front_leg"), (L("Left middle leg", "왼쪽 가운데 다리"), "left_middle_leg"),
            (L("Left hind leg", "왼쪽 뒷다리"), "left_hind_leg"), (L("Right front leg", "오른쪽 앞다리"), "right_front_leg"),
            (L("Right middle leg", "오른쪽 가운데 다리"), "right_middle_leg"), (L("Right hind leg", "오른쪽 뒷다리"), "right_hind_leg")
        ])
        addPopupItems(flashEye, [(L("Left eye", "왼쪽 눈"), "left"), (L("Right eye", "오른쪽 눈"), "right"), (L("Both eyes", "양쪽 눈"), "both")])
        addPopupItems(foodVariant, ["apple", "banana", "cheese", "grapes", "cookie", "sugar_cube"].map { (LabToy.foodName($0), $0) })
        _ = LabForm.status(foodStatusLabel)
        foodStatusLabel.isHidden = foodStatusLabel.stringValue.isEmpty
        func row(_ views: NSView...) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.spacing = 8
            return stack
        }
        constrainSize(panel.windDirectionDial, width: 36)
        return LabInspectorPage([
            section(L("Now at the fly", "지금 파리 위치의 값"),
                    help: L("Measured, not set: the latest body data from the physics simulator (position, odor, eye brightness, taste) and the receptor current the brain side actually injected this frame. Temperature and wind are the same everywhere in the arena; odor and light depend on where the fly is.", "설정값이 아니라 측정값입니다. 물리 시뮬레이터가 보낸 최신 몸 데이터(위치·냄새·눈 밝기·맛)와, 뇌 쪽이 이번 프레임에 감각 뉴런에 실제로 넣은 전류입니다. 온도와 바람은 사육장 어디서나 같고, 냄새와 빛은 파리가 있는 곳에 따라 달라집니다."),
                    [panel.sample]),
            section(L("Temperature", "온도"), kind: .sensoryModel,
                    help: L("Applies as you drag. ‘Thermosensory neurons’ drives TRN_VP2 (warm) and TRN_VP3a/b (cool); the current saturates 10 °C away from 25 °C. ‘Record only’ stores the value with no neural input. The temperature→current conversion is a modeling assumption. The simulator accepts 0–50 °C; this panel offers 10–40 °C.", "끌면 바로 적용됩니다. ‘온도 감각 뉴런에 전달’은 따뜻함 뉴런(TRN_VP2)과 차가움 뉴런(TRN_VP3a/b)을 자극하며, 25 °C에서 10 °C 넘게 벗어나면 더 세지지 않습니다. ‘기록만’은 값만 저장하고 뇌에는 전달하지 않습니다. 온도를 신경 전류로 바꾸는 비율은 모델이 가정한 값입니다. 시뮬레이터는 0–50 °C를 받지만 이 패널은 10–40 °C를 다룹니다."),
                    [LabForm.grid([("°C", row(panel.temperatureSlider, panel.temperatureField)),
                                   (L("Mode", "방식"), panel.temperatureMode)]),
                     panel.temperatureApplied, panel.temperatureStatus]),
            section(L("Wind", "바람"), kind: .sensoryModel,
                    help: L("Strength, direction and the two switches set a continuous wind and apply as you change them; strength 0 or Stop turns it off. Direction is in world coordinates: the dial shows, seen from above, where the wind blows (right = +X, up = +Y). ‘Push the body’ is a MuJoCo force on the thorax; ‘antenna wind sense’ drives the JO-C/E groups using the wind's angle to the fly. The push fades as the fly approaches the wind's speed (30 mm/s at strength 1); strong wind, especially head-on, can tip the fly over. A puff blows once for the set time and then stops — it does not resume a continuous wind. Strength is dimensionless, not m/s.", "세기·방향·두 스위치는 ‘계속 부는 바람’을 정하며, 바꾸는 즉시 적용됩니다. 세기 0이나 ‘바람 끄기’로 끕니다. 방향은 세계 좌표입니다. 다이얼은 위에서 본 바람이 부는 쪽입니다(오른쪽 = +X, 위 = +Y). ‘몸을 실제로 밀기’는 물리 엔진에서 가슴을 미는 힘이고, ‘더듬이 바람 감각’은 파리와 바람의 각도로 JO-C/E 뉴런 그룹을 자극합니다. 파리가 바람 속도(세기 1에서 30 mm/s)에 가까워질수록 미는 힘이 줄어듭니다. 센 바람, 특히 정면 바람은 파리를 넘어뜨릴 수 있습니다. ‘한 번 불기’는 정한 시간만 불고 멈추며, 계속 부는 바람으로 돌아가지 않습니다. 세기는 단위 없는 값이며 m/s가 아닙니다."),
                    [LabForm.grid([(L("Strength 0–1", "세기 0–1"), row(panel.windStrengthSlider, panel.windStrengthField)),
                                   (L("Direction (°)", "방향 (°)"), row(panel.windDirectionDial, panel.windDirectionField))]),
                     panel.windPhysical, panel.windSensory,
                     LabForm.buttons([panel.windOnButton, panel.windOffButton]),
                     panel.windApplied, panel.windStatus,
                     LabForm.grid([(L("Puff (ms)", "한 번 (ms)"), windDuration)]),
                     LabForm.buttons([button(L("Blow once", "한 번 불기"), #selector(applyWindPuff))], columns: 1)]),
            section(L("Light", "빛"), kind: .sensoryModel,
                    help: L("Covering scales the rendered image reaching that eye (100% = dark). Flash raises full-field brightness for a moment; there is no photoreceptor pathway or invented flash-to-escape circuit. The scene lighting itself is fixed and cannot be edited.", "가림은 그 눈에 들어가는 실제 화면 밝기를 줄입니다(100% = 깜깜함). 번쩍임은 잠깐 눈 전체 밝기만 올립니다. 광수용체 경로나 ‘번쩍이면 도망’ 회로를 따로 만들어 넣지 않았습니다. 장면 조명 자체는 고정이라 바꿀 수 없습니다."),
                    [LabForm.grid([(L("Left eye cover", "왼쪽 눈 가림"), row(panel.leftMaskSlider, panel.leftMaskValue)),
                                   (L("Right eye cover", "오른쪽 눈 가림"), row(panel.rightMaskSlider, panel.rightMaskValue))]),
                     panel.lightApplied, panel.lightStatus,
                     LabForm.grid([(L("Flash", "번쩍임"), flashEye), (L("Intensity 0–1", "세기 0–1"), flashIntensity),
                                   (L("Duration (ms)", "지속 시간 (ms)"), flashDuration)]),
                     LabForm.buttons([button(L("Flash", "번쩍이기"), #selector(applyFlash))], columns: 1)]),
            section(L("Food", "먹이"), kind: .sensoryModel,
                    help: L("Each food is an odor source: concentration falls off with distance (30 mm decay) and is split between the left and right antennae by direction. There is no wind-carried plume. Touching it with the mouth gives a modeled sugar-taste signal and slowly eats it. Move or delete food in the World page or Edit mode.", "먹이마다 냄새가 납니다. 냄새는 거리에 따라 줄고(30 mm마다 약 1/e), 방향에 따라 왼쪽·오른쪽 더듬이에 나뉘어 들어갑니다. 바람에 실려 퍼지는 냄새는 없습니다. 입이 닿으면 모델이 만든 ‘단맛’ 신호가 나오고 먹이가 조금씩 줄어듭니다. 옮기거나 지우려면 ‘세계’ 화면이나 편집 모드를 쓰세요."),
                    [panel.foodSummary,
                     LabForm.grid([(L("Kind", "종류"), foodVariant)]),
                     LabForm.buttons([button(L("Place 15 mm in front of the fly", "파리 앞 15 mm에 놓기"), #selector(placeFoodInFront))], columns: 1),
                     foodStatusLabel]),
            section(L("Touch", "건드리기"), kind: .physical,
                    help: L("An impulse on the chosen body part. The neural side is a generic touch/startle channel, not body-part-specific transduction.", "고른 몸 부위를 한 번 툭 칩니다. 뇌 쪽 입력은 부위와 상관없는 일반적인 ‘닿음/놀람’ 신호입니다."),
                    [LabForm.grid([(L("Body part", "몸 부위"), touchTarget), (L("Strength 0–1", "세기 0–1"), touchStrength),
                                   (L("Duration (ms)", "지속 시간 (ms)"), touchDuration)]),
                     LabForm.buttons([button(L("Apply touch", "건드리기 실행"), #selector(applyTouch)),
                                      button(L("Reset stimuli", "자극 모두 끄기"), #selector(resetSenses))])])
        ])
    }

    func brainPage() -> NSViewController {
        let brainView: NSView
        if let brainController {
            let view = brainController.embeddedView
            view.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false
            constrainSize(view, height: 280)
            view.wantsLayer = true
            view.layer?.cornerRadius = 8
            view.layer?.masksToBounds = true
            brainView = view
        } else {
            brainView = LabForm.note(L("The brain model is not loaded in this session.", "이번 실행에서는 뇌 모델을 불러오지 않았습니다."))
        }
        addPopupItems(brainRole, NeuronGuide.groups.compactMap { group in
            group.stimulusID.map { (group.name, $0) }
        })
        brainRole.target = self
        brainRole.action = #selector(brainRoleChanged)
        _ = LabForm.status(brainRoleDescription)
        updateBrainRoleDescription()
        _ = LabForm.number(brainStrength); _ = LabForm.number(brainDuration)
        _ = LabForm.status(brainSelectionLabel)
        _ = LabForm.status(brainObservationLabel, mono: true)
        updateBrainObservation()
        return LabInspectorPage([
            section(L("Sampled spike visualization", "표본 발화 시각화"),
                    help: L("All 139,255 somata are shown. Flashes are a lossy sample, without exact counts or timing. Data rates use exact simulated spike counts per neuron and an approximately 120 ms simulation-time EMA. A click only selects a cluster for exact observation; it stimulates only while the ⚡ switch in the view is on.", "뉴런 139,255개를 표시합니다. 반짝임은 일부 발화만 보여 주며 정확한 횟수·시간을 뜻하지 않습니다. Data 발화율은 실제 시뮬레이션 집계의 뉴런당 평균, 약 120 ms simulation-time EMA입니다. 클릭은 정확 관측할 뉴런 덩어리를 고르기만 하며, 화면 안의 ⚡ 스위치를 켰을 때만 직접 자극합니다."),
                    [LabForm.note(L("Sampled flashes — counts and timing are incomplete. Click = select (no stimulation). ⚡ switch on = click stimulates.", "표본 반짝임 — 횟수·시간이 불완전합니다. 클릭 = 선택(자극 없음). ⚡ 스위치를 켜면 클릭 = 직접 자극.")), brainView]),
            section(L("Selected neurons — exact observation (read-only)", "선택한 뉴런 — 정확 관측 (읽기 전용)"),
                    help: String(format: L("Exact spike counts for up to %d selected neurons, read from the simulation every 1 ms step (not the sampled flashes). Rate = spikes × 1000 ÷ (observed ms × neurons), in Hz per neuron. Ticks before the selection or older than %.3f s are reported as missing, never as zeros. Selecting never injects current.", "선택한 뉴런 최대 %d개의 발화를 시뮬레이션 1 ms 단계마다 정확히 셉니다(표본 반짝임이 아님). 발화율 = 발화 수 × 1000 ÷ (관측한 ms × 뉴런 수), 뉴런당 Hz입니다. 선택하기 전이나 %.3f초보다 오래된 구간은 0이 아니라 ‘빠진 구간’으로 표시합니다. 선택만으로는 전류를 넣지 않습니다."),
                                   ObservationCapability.exactSelectionLimit, Double(ObservationCapability.retainedTicks) / 1000),
                    [brainSelectionLabel, brainObservationLabel,
                     LabForm.buttons([button(L("Clear selection", "선택 해제"), #selector(clearBrainSelection))], columns: 1)]),
            eventWindowsSection(),
            section(L("What the colours mean", "색 안내 — 각 뉴런이 하는 일"),
                    [NeuronGuide.legendView()]),
            section(L("Stimulate a population", "뉴런 그룹 직접 자극하기"), kind: .directNeural,
                    help: L("Bypasses the physical stimulus and sense organs: the chosen FlyWire population is driven directly while the rest of the brain runs normally. Labels describe the modeled readout, not a guaranteed behavior.", "눈·더듬이 같은 감각기관을 거치지 않고 고른 뉴런 그룹만 직접 자극합니다. 나머지 뇌는 평소처럼 돌아갑니다. 이름 옆 설명은 그 뉴런이 모델에서 주로 맡는 일이며, 자극하면 반드시 그 행동이 나온다는 뜻은 아닙니다."),
                    [LabForm.grid([(L("Population", "뉴런 그룹"), brainRole), (L("Strength", "세기"), brainStrength),
                                   (L("Duration (ms)", "지속 시간 (ms)"), brainDuration)]),
                     brainRoleDescription,
                     LabForm.buttons([button(L("Stimulate", "자극하기"), #selector(stimulateBrain))], columns: 1)])
        ])
    }

    @objc private func brainRoleChanged() { updateBrainRoleDescription() }

    @objc func clearBrainSelection() {
        coordinator.clearBrainObservation()
        brainController?.clearSelectionMarker()
    }

    /// Refreshes the exact-observation readout (called from `refresh()`).
    func updateBrainObservation() {
        guard let (info, last1s) = coordinator.brainObservation(windowMs: 1000) else {
            brainSelectionLabel.stringValue = L("The brain model is not loaded.", "뇌 모델을 불러오지 않았습니다.")
            brainObservationLabel.stringValue = ""
            return
        }
        if let pending = coordinator.sim?.observer.pending() {
            brainSelectionLabel.stringValue = pending.isEmpty
                ? L("Clearing the selection — applies when the simulation runs.", "선택 해제 대기 — 시뮬레이션이 돌면 적용됩니다.")
                : "◎ \(pending) — " + L("queued; exact observation starts when the simulation runs (paused now?)", "대기 중; 시뮬레이션이 돌면 정확 관측을 시작합니다 (지금 일시 정지?)")
            brainObservationLabel.stringValue = ""
            return
        }
        guard !info.isEmpty else {
            brainSelectionLabel.stringValue = L("Nothing selected — click the brain above.", "선택 없음 — 위 뇌를 클릭하세요.")
            brainObservationLabel.stringValue = String(format: L("exact limit %d neurons · retained %d ms", "정확 관측 한도 뉴런 %d개 · 보관 %d ms"),
                                                       ObservationCapability.exactSelectionLimit, ObservationCapability.retainedTicks)
            return
        }
        var head = "◎ \(info.name) — " + String(format: L("%d neurons observed exactly", "뉴런 %d개 정확 관측"), info.neurons.count)
        if info.omitted > 0 {
            head += String(format: L(" (%1$d more beyond the %2$d limit are NOT observed)", " (한도 %2$d개를 넘은 %1$d개는 관측 안 함)"),
                           info.omitted, ObservationCapability.exactSelectionLimit)
        }
        if let first = info.neurons.first, let label = brainController?.neuronLabel(first) {
            head += "\n" + L("nearest: ", "가장 가까운 뉴런: ") + label
        }
        brainSelectionLabel.stringValue = head
        let all = coordinator.brainObservation(windowMs: nil)?.1
        func line(_ title: String, _ o: NeuralObservation?) -> String {
            guard let o else { return title + L(": no simulated step yet", ": 아직 계산된 단계 없음") }
            let rate = o.rateHzPerNeuron.map { String(format: "%.2f Hz/%@", $0, L("neuron", "뉴런")) } ?? "—"
            var t = String(format: L("%@: %d spikes · %@ · t=%d…%d (%d ms)", "%@: 발화 %d회 · %@ · t=%d…%d (%d ms)"), title, o.spikeCount, rate,
                           o.startTick, o.endTick, o.observedTicks)
            if o.droppedSamples > 0 { t += String(format: L(" · %d ms missing", " · %d ms 빠짐"), o.droppedSamples) }
            return t + " · " + o.source.rawValue + "/" + o.validity.rawValue
        }
        brainObservationLabel.stringValue = line(L("last 1 s", "최근 1초"), last1s) + "\n"
            + line(L("retained", "보관 전체"), all) + "\n"
            + String(format: L("epoch %d · selection #%d", "epoch %d · 선택 #%d"), info.brainEpoch, info.selectionID)
    }

    func updateBrainRoleDescription() {
        let group = NeuronGuide.group(stimulusID: selectedValue(brainRole, fallback: "GF"))
        brainRoleDescription.stringValue = group.map { "→ " + $0.what } ?? ""
    }

    /// Colour key for the 3D brain: swatch, name and one plain sentence per row.
    func metricsPage() -> NSViewController {
        neuralGraph.fixedRange = 0...220
        commandGraph.fixedRange = 0...220
        sensoryGraph.fixedRange = 0...1.2
        flywireSensoryGraph.fixedRange = 0...0.065
        flywireSensoryGraph.valueDecimals = 3
        flywireSensoryGraph.unitLabel = L("injected current · sim units", "넣어 준 전류 · 시뮬레이션 단위")
        bodyGraph.fixedRange = -1.2...1.2
        visionGraph.fixedRange = 0...1.05
        for text in [bodyTelemetryLabel, foodTelemetryLabel, visionTelemetryLabel] {
            _ = LabForm.status(text, mono: true)
        }
        for g in graphs {
            g.translatesAutoresizingMaskIntoConstraints = false
            constrainSize(g, height: 120)
        }
        activityCards = ActivityCardPanel(selected: activityCards.selectedCard)
        return LabInspectorPage([
            section(L("Activity cards (read-only)", "활동 카드 (읽기 전용)"),
                    help: ActivityCardPanel.helpText, [activityCards]),
            section(L("Signal path", "신호 경로 — 감각에서 몸까지"),
                    help: L("Read top to bottom to find where a response stops. Each line uses only telemetry the runtime actually exposes.", "위에서 아래로 읽으면 자극이 어디까지 전달됐는지 알 수 있습니다: 1 바깥 자극 → 2 감각 신호 → 3 뉴런 반응 → 4 몸에 내린 명령 → 5 실제 움직임. 모두 실제로 측정된 값만 씁니다."),
                    [signalPathLabel]),
            section(L("Brain rate (Hz/neuron)", "뇌 발화율 (Hz/뉴런)"),
                    help: L("Exact simulated spike counts divided by population size; approximately 120 ms simulation-time EMA, not a fixed window or animation count. walk/back/groom are DN rates, not guaranteed behavior.", "실제 시뮬레이션 발화 집계를 그룹 뉴런 수로 나눈 뉴런당 발화율입니다. 약 120 ms simulation-time EMA이며 고정 구간 평균·반짝임 횟수가 아닙니다. walk/back/groom은 운동 뉴런 발화율이며 행동을 보장하지 않습니다."),
                    [neuralGraph]),
            section(L("Descending rates (Hz/neuron)", "운동 뉴런 발화율 (Hz/뉴런)"),
                    help: L("DNa L/R steering, MDN backward, DNp09 forward walking, DNg11 grooming, escW escape/wing.", "뇌에서 몸으로 명령을 내리는 뉴런입니다. DNa L/R=왼쪽/오른쪽으로 돌기, MDN=뒤로 걷기, DNp09=앞으로 걷기, DNg11=몸 손질, escW=도망·날개."),
                    [commandGraph]),
            section(L("Compact sensory inputs", "주요 감각 입력"),
                    help: L("Loom is the left/right visual expansion signal; gait is body feedback; legacy air is the older generic channel, not JO-C/E wind.", "loom L/R=왼쪽/오른쪽 눈에 무언가 커지며 다가오는 신호, gait=다리가 땅을 딛는 감각, legacy air=예전 방식의 바람 신호(더듬이 바람 감각과는 다름)."),
                    [sensoryGraph]),
            section(L("FlyWire sensory groups", "감각 뉴런 그룹에 들어가는 신호"),
                    help: L("Modeled current injected into real receptor groups (ORN food odor, TRN warm/cool, JO-C/E wind). Expected maxima are about 0.055–0.060.", "실제 감각 뉴런 그룹에 넣어 준 신호 세기입니다. food=먹이 냄새(후각 뉴런 ORN), warm/cool=따뜻함/차가움(TRN), wind C/E=더듬이 바람 감각(JO-C/E). 최대 약 0.055–0.060입니다."),
                    [flywireSensoryGraph, foodTelemetryLabel]),
            section(L("Body", "몸"),
                    help: L("Speed ×20, turn ÷5 and nearest-food distance ÷100 share one axis; exact values are listed below.", "속도(×20), 회전(÷5), 가장 가까운 먹이까지 거리(÷100)를 한 그래프에 맞춰 그렸습니다. 정확한 값은 아래에 있습니다."),
                    [bodyGraph, bodyTelemetryLabel]),
            section(L("Rendered-eye vision", "파리 눈에 보이는 것"),
                    help: L("Brightness is mean light; target is configured-color occupancy; expansion is a raw-frame optic-expansion proxy, not reconstructed retinotopy.", "파리 눈 카메라로 본 화면에서 계산합니다. light=밝기, target=표시 색 물체가 차지하는 비율, expand=물체가 커지는 정도(다가옴의 단서)."),
                    [visionGraph, visionTelemetryLabel]),
            section(L("Connection", "연결 상태"), [remoteStateLabel, freshnessLabel, commandDiagnosticsLabel,
                                   LabForm.buttons([button(L("Clear graphs", "그래프 지우기"), #selector(clearGraphs))], columns: 1)])
        ])
    }

    func experimentPage() -> NSViewController {
        return LabInspectorPage([
            section(L("Session", "세션"),
                    help: L("Interactive is the responsive default. Deterministic starts a tick-zero brain/body session: 1 ms neural ticks and one exact 20 ms FlyGym quantum at a time, independent of display FPS. Pause and Resume are in the toolbar.", "기본은 반응이 빠른 실시간 모드입니다. ‘재현 가능한 세션’은 시간을 0부터 다시 시작해 뇌는 1 ms, 몸은 20 ms 단위로 정확히 맞춰 계산하므로 같은 실험을 똑같이 되풀이할 수 있습니다. 일시 정지/재개는 위쪽 막대에 있습니다."),
                    [sessionStatusLabel,
                     LabForm.buttons([button(L("Start deterministic session", "재현 가능한 세션 시작"), #selector(startDeterministicSession))],
                                     columns: 1)]),
            section(L("Markers", "구간 표시"),
                    help: L("Markers never change the simulation; they label the timeline and the recording so baseline, stimulus and observation periods line up later. Record from the toolbar; files go to Documents/ThongpariFlyNeuronSimExperiments.", "구간 표시는 시뮬레이션을 바꾸지 않고, 나중에 기록을 볼 때 ‘기준/자극/관찰’ 구간을 구분하도록 이름표만 붙입니다. 기록은 위쪽 막대의 ‘기록’ 버튼으로 하며 파일은 문서/ThongpariFlyNeuronSimExperiments에 저장됩니다."),
                    [LabForm.buttons([markerButton(L("Baseline", "기준 구간"), "baseline"),
                                      markerButton(L("Stimulus on", "자극 시작"), "stimulus_on"),
                                      markerButton(L("Stimulus off", "자극 끝"), "stimulus_off"),
                                      markerButton(L("Observation", "관찰 구간"), "observation")])]),
            section(L("Physical & sensory trials", "물리·감각 실험 예시"), kind: .physical,
                    help: L("Presets use the same World and Stimuli controls. They move objects or apply stimuli; they never command the fly.", "세계·자극 메뉴와 같은 조작을 한 번에 해 주는 예시입니다. 물체를 움직이거나 자극만 줄 뿐, 파리에게 직접 명령하지 않습니다."),
                    [LabForm.buttons([presetButton(L("Frontal loom", "정면에서 물체 접근"), "frontal_loom"),
                                      presetButton(L("Loom from left", "왼쪽에서 물체 접근"), "left_loom"),
                                      presetButton(L("Loom from right", "오른쪽에서 물체 접근"), "right_loom"),
                                      presetButton(L("Loom, left eye covered", "왼눈 가리고 물체 접근"), "left_eye_covered_loom"),
                                      presetButton(L("Wind puff", "바람 한 번"), "wind_puff"),
                                      presetButton(L("Thorax touch", "가슴 건드리기"), "thorax_touch")])]),
            section(L("Direct neural trials", "뉴런 직접 자극 실험"), kind: .directNeural,
                    help: L("Explicit neural probes that bypass the natural stimulus.", "자연스러운 자극 없이 특정 뉴런 그룹만 직접 자극하는 실험입니다."),
                    [LabForm.buttons([presetButton(L("Escape (GF)", "비상 탈출 (GF)"), "gf"),
                                      presetButton(L("Turn left (DNa)", "왼쪽 돌기 (DNa)"), "dna_left"),
                                      presetButton(L("Turn right (DNa)", "오른쪽 돌기 (DNa)"), "dna_right"),
                                      presetButton(L("Walk backward (MDN)", "뒤로 걷기 (MDN)"), "mdn"),
                                      presetButton(L("Walk forward (DNp09)", "앞으로 걷기 (DNp09)"), "dnp09")])]),
            section(L("Repeat", "반복"),
                    [LabForm.buttons([button(L("Replay last preset", "마지막 실험 다시 하기"), #selector(replayLastPreset)),
                                      button(L("Reset everything", "전부 초기화"), #selector(resetAll))])])
        ])
    }
}
