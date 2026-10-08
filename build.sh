#!/bin/zsh
# Build Thongpari Fly Neuron Sim
cd "$(dirname "$0")"
# Every Swift file under Sources/ is one module; order does not matter.
swiftc -O -wmo -D DIAGNOSTICS -Xlinker -dead_strip -swift-version 5 -j"$(sysctl -n hw.ncpu)" -o ThongpariFlyNeuronSim Sources/**/*.swift \
    -framework Cocoa -framework SceneKit -framework Metal || exit 1
echo "Built ./ThongpariFlyNeuronSim"
