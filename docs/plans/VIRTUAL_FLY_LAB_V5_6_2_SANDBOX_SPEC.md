# Virtual Fly Lab V5.6.2 — 샌드박스 환경·모델·섭식 계약

작성: 2026-09-27 · 상태: **구현·자동 검증 완료, GUI 확인 대기** · 순서: V5.6.1 → **V5.6.2** → V5.7 → V6

사용자 요청(2026-09-27): V5.7 전에 시뮬 환경을 바꾼다. 참여체는 쫄라맨, 배경은 정사각형 잔디밭, 파리는 색을 입힌 모델, 음식은 생성할 때마다 여러 종류의 3D 모델, 음식을 들어서 파리를 유인, 비비탄총·자동차·함정 생성, 파리가 음식을 먹고 신경 반응이 연결되며 먹으면 사라진다.

## 0. 로드맵 대조

| 요청 | 기존 계획 | 처리 |
|---|---|---|
| 음식 들기·유인 | V5.6에서 구현됨(먹이도 잡아서 옮길 수 있고 냄새원이 함께 움직임) | 변경 없음 |
| 쫄라맨, 잔디밭, 파리 색, 음식 모델, 자동차·함정·비비탄총 | V6–V14 어디에도 없음 | V5.6.2에서 구현 |
| 섭식 + 미각 신경 반응 | 접촉 미각은 V10 §10.7(1차 주석 root ID 확인 조건), 욕구는 V11 | 사용자 직접 요청으로 **V10 §10.7의 근거 조건을 지키며** 최소판을 앞당김. 보상·배고픔·섭식 운동 프로그램은 만들지 않음 |

## 1. 모델링 원칙 (`flygym_bridge/sandbox_models.py`)

- 모든 모델은 MuJoCo primitive로, Simulation 컴파일 전에 설치한다. 슬롯마다 부품 geom **palette**를 미리 컴파일하고 실행 중 `Palette.fill`로 위치·크기·색을 채운다.
- 쓰지 않는 부품은 alpha 0이다. MuJoCo 3.9.0에서 alpha 0 geom은 `mjv_updateScene`과 `mj_ray` 모두에서 빠진다(2026-09-27 실측: ray가 가린 geom을 통과, scene ngeom 1).
- 컴파일 때 몸체 원점에 있던 geom은 `geom_sameframe`으로 표시되어 실행 중 `geom_pos`/`geom_quat` 변경이 무시된다. `Palette.bind`가 이 플래그를 0으로 바꾼다.
- 부품 크기는 최대 크기로 컴파일해 `geom_rbound`/aabb를 보수적으로 둔다.
- **명시 pair는 contype/conaffinity를 무시한다.** 그래서 pair는 항상 solid인 부품에만 건다. 비활성 슬롯은 FAR_POS(z −500 mm)에 둔다.
- 장식 부품(`collide=False`)은 충돌 부품 표면이나 안쪽에 있으며 차이는 수십 분의 1 mm 이하다. 예외는 장난감 총(§2)이며 따로 명시한다.
- 색 제약: 어떤 부품도 loom 검출 목표색(magenta 0.92/0.08/0.72)의 chroma 0.105 안에 들어가지 않는다.

## 2. 참여체 쫄라맨 (`player_body.py`)

- 머리 구 = 기존 참여체 geom이다. 반경 2.5 mm, 중심 = 참여체 위치, `collision_radius_mm` 계약은 그대로다. 팔다리는 같은 free-joint 몸체의 capsule 5개(몸통, 팔 2, 다리 2)이며 모두 충돌한다.
- 발이 바닥에 닿지 않게 머리 중심 높이를 `FIGURE_HEAD_HEIGHT_MM`(10.3 mm)로 올린다. 발 아래 간격은 0.08 mm다(FlyGym 바닥은 명시 pair만 충돌하므로 참여체는 바닥과 접촉하지 않는다).
- **몸체 방향은 yaw만 따른다.** 위아래 시선(pitch)은 카메라에만 있다. `PlayerPose.orientation_quat_xyzw`는 이제 시선(카메라) 방향이고, 충돌 몸체 프레임은 그 yaw 성분이다. 그래서 위를 봐도 몸이 기울지 않는다.
- 팔다리 capsule ↔ 파리 thorax/head/abdomen 명시 pair를 추가한다. 머리 ↔ thorax pair는 기존대로다.
- 운반 제약의 참여체 후보는 머리와 팔다리 전부(`solid_geom_ids`)다.
- 1인칭에서는 머리와 얼굴만 숨긴다. 팔다리와 총은 보인다.
- 장난감 비비탄총: 오른손에 드는 표시 전용 모형이며 **비충돌**이다. 총을 들면 오른팔(충돌 capsule)이 앞으로 올라간다. API는 `PlayerBody.set_gun_visible(bool)`이다.
- 작업 공간은 잔디밭 안쪽(±145 mm)이다.
- 잡기 거리 한도는 12 → 16 mm다(`INTERACTION_REACH_MM`). 눈이 10.3 mm 높이라 앞 9 mm 바닥 물건이 이미 머리 중심에서 약 12.6 mm 떨어져 있다.

## 3. 잔디밭과 파리 색 (`fly_body.py`)

- `style_arena`: FlyGym 회색 체커를 잔디 텍스처로 바꾸고 평면을 300×300 mm로 줄인다. MuJoCo plane은 크기와 무관하게 무한 평면으로 충돌하므로 접지·좌표·기존 실험은 그대로다. 평균 휘도(약 0.36)는 기존 체커(0.30/0.40)와 비슷하다.
- 파리는 `make_locomotion_fly(colorize=True)`로 FlyGym에 들어 있는 NeuroMechFly 공식 재질을 쓴다.

## 4. 음식 모델

- 종류: apple, banana, cheese, grapes, cookie, sugar_cube. 따로 지정하지 않으면 생성할 때마다 이 순서로 돌아가며 나온다. 결정론적이고 `reset_world`에서 처음으로 돌아간다.
- `spawn_food`에 `variant`를 선택 인자로 줄 수 있다. 음식이 아닌 물체에 주거나 없는 종류를 주면 거절한다.
- 상태와 render snapshot에 `food_variant`가 붙는다. 냄새 모델은 종류와 무관하게 기존과 같다(구 반경 기준).

## 5. 섭식 (`lab_world.feeding_update`)

- 판정: 주둥이 끝 geom `c_haustellum`과 음식 부품의 `mj_geomDistance`가 `FEED_CONTACT_MM`(0.15 mm) 이하이면 먹는 중이다. 가장 가까운 음식 하나만 먹는다. 계산은 물리 quantum마다 한 번이다.
- 먹는 동안 지름이 `FEED_SHRINK_MM_S`(1.2 mm/s)로 줄고, 음식은 바닥에 놓인 채 줄어든다. `FEED_MIN_DIAMETER_MM`(0.4 mm) 미만이 되면 사라진다.
- 사건: `feeding_begin`, `feeding_end`, `food_eaten`.
- 신호: BodyPacket `taste_sugar`(0..1, 먹는 중일 때만 0보다 큼)와 `eating_food_id`. 당 함량은 종류별 표(`FOOD_SUGAR`)를 쓰며 **모델 가정**이다(측정 화학 아님).
- 제약: 주둥이는 구동되지 않는다(FlyGym LEGS_ONLY). 섭식 운동 프로그램, 보상, 배고픔, 스크립트된 접근 행동은 없다. 냄새만으로는 맛 신호가 생기지 않는다.
- 신경 연결(Swift, `MetalSim.IdentifiedTasteNeurons`):
  - 당 GRN 21개는 github.com/eonsystemspbc/fly-brain @ `a3db62f9` `code/benchmark.py` `EXPERIMENTS['sugar']`에서 가져왔다. 우리 connectivity parquet과 같은 출처의 v783 목록이며, Shiu et al. 2024 Nature의 v630 목록과는 1개가 다르다. 21개 모두 우리 `rootId`와 일치하고, manifest `side=left`, type `LB3`다.
  - MN9 2개는 같은 커밋의 `example.ipynb`에서 가져왔고 읽기 전용이다.
  - 전류: `0.120 × sugar^¼ × sensoryGate`이며 모델 가정이다.
  - 측정: 당 GRN은 sugar 0 → 1.0에서 0 → 85 Hz였다. MN9는 3개 seed 평균 13.7 → 34.2 Hz였고, 냄새만 줄 때는 14.4 Hz였다. `--gpucheck`는 bit-exact를 유지한다.
  - 한계: v783로 확인된 목록은 한쪽 labellum뿐이다. MN9는 네트워크 반응일 뿐 주둥이 운동이 아니다.

## 6. 도구: 자동차·함정·비비탄 (모델은 `sandbox_models`, 동작 로직은 별도 단계)

- 자동차 `car`: mocap 슬롯이다. 차체·유리 캐빈·지붕·바퀴 4개는 충돌하고, 그릴·범퍼·등·휠캡은 장식이다. 크기는 길이 L(기본 14 mm)이며 폭 0.44L, 높이 0.41L다.
- 함정 `trap`: 반투명 유리 상자(벽 4 + 뚜껑은 충돌, 모서리 틀·손잡이는 장식)이며 한 변 S(기본 20 mm), 높이 0.6S다.
- 비비탄: 반경 0.6 mm 구, 아이보리색이다. 총구 위치는 `BB_MUZZLE_OFFSET_MM`(참여체 몸체 프레임)이다.
- 동작 계약 (구현: Codex `gpt-6-sol` high, 2026-09-27):
  - 생성: `spawn_object {shape:"car"|"trap", id?, position_mm?, size_mm: 스칼라}`. 자동차 길이는 4–60 mm, 함정 한 변은 8–60 mm다. 충돌 부품 × 파리 thorax/head/abdomen 명시 pair를 둔다. 여러 부품 물체도 운반 제약·접촉 기록·ray 대상에 모두 포함된다.
  - `drive_object {id, speed_mm_s ∈ (0,60] 기본 20, distance_mm ∈ (0,300] 기본 80}`: 자동차만 대상이다. substep마다 진행 방향으로 움직이고, 이동 전 `mj_geomDistance`로 참여체와 다른 물체 앞에서 멈춘다(`car_blocked`). 파리와 실제로 접촉하면 멈추고 `car_hit_fly`(최대 법선력)를 낸다. 잔디 가장자리나 목표 거리에 이르면 `drive_complete`다. 잡기·이동·크기 변경·삭제·초기화 시 주행이 취소된다.
  - 함정: 상태는 `armed`(벽 하단이 바닥 위 4 mm라 파리가 아래로 드나듦), `dropping`(60 mm/s), `closed`(하단 0.02 mm) 순이다. 파리 thorax가 벽에서 2 mm 이상 안쪽에 있을 때만 작동하므로 벽이 파리 위로 떨어지지 않는다. 내려오다 막히면 멈춘다(`trap_blocked`). `arm_trap {id}`로 다시 올린다. 사건은 `trap_triggered`/`trap_closed`/`trap_armed`다.
  - 비비탄: `equip_gun {actor_id, equipped: bool}`, `fire_bb {actor_id, direction: 단위벡터}`. 탄환 풀은 free-joint 8개이고 질량 2e-5, 실제 중력을 받는다. 발사 간격은 0.15 s 이상, 최대 2 s 뒤 소멸한다(탄속은 아래 조준 수정 참고). 대기 중인 탄은 FAR_POS에 두고 gravcomp 1이다. 사건은 `bb_fired`/`bb_hit_fly`(부위, 힘)/`bb_hit_object`/`bb_expired`다. 총구와 참여체 충돌 부품의 간격은 최소 1.321 mm로 측정됐다.
  - **조준 수정 (2026-09-27, 사용자 보고 "총이 제대로 안 나감")**:
    - 원인: 탄이 조준선(눈)이 아닌 오른손 총구에서 시선과 평행하게 나가 약 3.2 mm 낮게 출발했고, 파리 크기 세계에서는 중력 낙차까지 더해져 바닥에 떨어졌다. 1500 mm/s라 화면에 거의 보이지도 않았다.
    - 수정 1: 조준점은 눈에서 시선 방향으로 쏜 `mj_ray`의 첫 명중점이다(없으면 150 mm 앞).
    - 수정 2: 총구에서 그 점까지 실제 중력에 맞는 낮은 탄도각으로 발사한다(`_ballistic_velocity`). 탄속은 2000 mm/s다.
    - 수정 3: 궤적선(최근 15 ms, 반투명 capsule)은 geom 그룹 3에 두어 사람 화면에만 보인다. FlyGym 눈 렌더러는 그룹 0만 그리므로 파리의 시각 입력에는 들어가지 않는다.
    - 검증: 60 mm 앞 바닥 조준점에 0.30 mm 차이로 착탄했다. 예전 방식(평행 발사)은 24 mm 빗나가 음성 대조에서 FAIL이다. 궤적선은 비행 중 표시되고, 눈 렌더러에서는 그룹이 꺼져 있음을 확인했다.
  - 파리의 반응은 스크립트가 아니다. 물리 접촉과 기존 시각·감각 경로만으로 생긴다.
  - 비용: 도구 슬롯을 설치하고 쓰지 않을 때 body step 오버헤드는 3.22%다(쌍 비율 중앙값, 30쌍, 기준 5%).

## 7. 검증

- Python 회귀 10종, Swift 회귀, TCP mock/headless를 돌린다.
- 새 시험: 모델 palette 채우기와 숨기기, 음식 종류 순환·지정·거절, 쫄라맨 yaw 전용 몸체와 시선 pose, 팔다리↔파리 접촉, 섭식(접촉 시 축소·사라짐·사건, 먼 음식 무변화, 냄새만으로 맛 신호 0), vision 회귀.
- GUI 확인: 오케스트레이터가 새 프로세스 앱에서 캡처한다.
