#!/bin/zsh
# Build Thongpari Fly Neuron Sim
cd "$(dirname "$0")"
swiftc -O -swift-version 5 -o ThongpariFlyNeuronSim main.swift FlyModel.swift FlyGymPackets.swift FlyGymBridge.swift FlyGymService.swift BridgeDiagnostics.swift LabSession.swift LabProtocol.swift LabDiagnostics.swift LabViewState.swift PlayerController.swift LabGraphView.swift ExperimentRecorder.swift WorldViewer.swift LabLocalization.swift NeuronGuide.swift FlyMood.swift LabChrome.swift MuJoCoCanvas.swift LabWindow.swift SensoryModel.swift MotorReadout.swift \
    Sim.swift MetalSim.swift GPUCheck.swift Diagnostics.swift SimDiagnostics.swift BrainView.swift Environment.swift \
    -framework Cocoa -framework SceneKit -framework Metal || exit 1
echo "Built ./ThongpariFlyNeuronSim"
