# Thongpari Fly Neuron Sim 실행 파일 안내

Virtual Fly Lab의 기본 진입점은 저장소 루트의 **`Virtual Fly Lab.command`**다. Finder에서 더블클릭하면 `run_flygym.sh`를 호출한다. CLI에서는 저장소 루트에서 `./run_flygym.sh`를 사용한다. `flygym-venv/bin/python`이 필요하며, 두 경로 모두 필요하면 Swift 실행 파일을 다시 빌드한 뒤 `./ThongpariFlyNeuronSim --lab`을 실행한다.

기본 `--lab` 모드에서는 앱이 비공개 loopback 포트의 실제 FlyGym/MuJoCo **headless bridge**를 소유한다. MuJoCo viewer 창을 별도로 띄우지 않고 한 Lab 창에 세계를 표시하며, 앱 종료 시 자식 bridge를 정리한다. 첫 backend 준비에는 시간이 걸릴 수 있다. 사용법은 [`VIRTUAL_FLY_LAB_GUIDE.md`](VIRTUAL_FLY_LAB_GUIDE.md)를 참고한다.

## 실행 모드

| 명령 | 경로와 용도 |
|---|---|
| `./run_flygym.sh` | 기본 한 창 Lab + 앱 소유 실제 headless bridge, 비공개 포트 |
| `./run_flygym.sh --mock` | 한 창 Lab + 앱 소유 mock bridge; MuJoCo 없는 UI 점검용 |
| `./run_flygym.sh --viewer` | **개발 진단용** 실제 backend + 별도 MuJoCo viewer 창; 기본 한 창 동선이 아님 |
| `./run_flygym.sh --bridge-only` | 앱 없이 실제 headless bridge만 `127.0.0.1:17841`에서 실행; 외부 연결/진단용 |
| `./ThongpariFlyNeuronSim --flygym` | 이미 실행 중인 **외부** `127.0.0.1:17841` bridge에 연결하는 Lab 창; bridge를 시작하거나 소유하지 않음 |
| `./ThongpariFlyNeuronSim` | 기존 데스크톱 오버레이 파리 모드; 통합 Lab 진입점이 아님 |

외부 bridge 모드는 첫 Terminal에서 `./run_flygym.sh --bridge-only`를 실행한 뒤, 다른 Terminal에서 `./ThongpariFlyNeuronSim --flygym`을 실행한다. `--bridge-only`는 17841 포트에 기존 listener가 있으면 종료한다. 기존 사용자 listener를 중단하지 않는다.

`run_flygym.sh`는 이전 런처의 `--flygym`과 `--flygym-headless`를 입력으로 받아들이지만 둘 다 현재 기본 headless Lab 경로와 같다. `bridge.py` 자체의 플래그는 다르다: `--mock`은 mock body, `--flygym-headless`는 실제 body와 viewer 없는 bridge, `--flygym`은 실제 body와 **별도 MuJoCo viewer**를 뜻한다. 앱 소유 bridge에는 `THONGPARI_BRIDGE_PORT`, headless 렌더에는 `THONGPARI_RENDER_PORT`, 부모 종료 감시에는 `THONGPARI_PARENT_PID`가 설정된다. 직접 실행한 외부 bridge의 기본 포트는 17841이다.

Finder용 앱 bundle이 필요하면 저장소 루트에서 다음을 실행한다. `package_app.sh`는 이 checkout을 가리키는 `dist/Thongpari Virtual Fly Lab.app`을 만든다.

```sh
./package_app.sh
```

## 진단

소켓을 사용하지 않는 Swift Lab 검사:

```sh
./ThongpariFlyNeuronSim --labtest
```

실제 TCP Lab 검사는 **새 진단용 bridge**를 별도 Terminal에서 시작한 뒤 실행한다. 기존 세션이 붙은 bridge에 검사 명령을 보내지 않는다.

```sh
./run_flygym.sh --bridge-only
```

다른 Terminal에서:

```sh
./ThongpariFlyNeuronSim --labloop
```

`--labloop`는 자체 객체의 생성·삭제와 자극 ACK/만료를 검사한다. 다른 진단을 연속 실행할 때는 각각 새 backend를 사용한다. 정적 검사와 Python 회귀의 상세 절차는 [`../reports/OVERALL_AUDIT_AND_FIX_PLAN_2026-09-22.md`](../reports/OVERALL_AUDIT_AND_FIX_PLAN_2026-09-22.md)를 참고한다.

기존 소켓 없는 bridge 검사와 Python Lab/preset 검사는 다음 경로에 있다.

```sh
./ThongpariFlyNeuronSim --bridgetest
./flygym-venv/bin/python flygym_bridge/test_lab.py
./flygym-venv/bin/python flygym_bridge/test_lab_real.py
./flygym-venv/bin/python flygym_bridge/validate_experiment_presets.py
```

Swift 소스를 바꾼 뒤 직접 실행 파일이 오래됐다면 `./build.sh`로 갱신한다. 기본 런처와 패키징 스크립트는 실행 파일이 없거나 빌드 입력보다 오래되면 다시 빌드한다.

위 모드 구분은 런처와 인수 처리 소스에서 확인했다. 이 안내를 따라 새 checkout에서 Finder 실행을 다시 검증했는지는 **미확인**이다.
