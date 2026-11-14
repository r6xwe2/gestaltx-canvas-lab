# 출처·변경 안내 / Attribution and modification notice

## 비공식 실험 패치

- 이름: GestaltX Canvas Lab 0.1
- 작성·수정일: 2026-11-14
- 이 키트는 사용자 요청에 따라 작성한 비공식 소스 추가분입니다. huamidev, forcequitOS, Apple이 배포·승인하거나 안정성을 보증한 버전이 아닙니다.
- 완성 IPA, Apple 인증서, 프로비저닝 프로파일, 사용자 기기 데이터는 포함하지 않습니다.

## 원본 프로젝트

GestaltX by huamidev and contributors:
https://github.com/huamidev/GestaltX

적용 대상 커밋:
`f34d5a7271c14e540edb58e328dc9c06f8f3368f` (v1.1.1)

원본 라이선스:
https://github.com/huamidev/GestaltX/blob/f34d5a7271c14e540edb58e328dc9c06f8f3368f/LICENSE

이 키트의 `apply_patch.py`에 포함된 원본 앱 진입점은 위 커밋의 `GestaltX/GestaltXApp.swift`에서 가져온 버전 확인용 내용입니다. 해당 내용과 원본 GestaltX의 권리는 원저작자에게 있습니다.

원본에서 포함하는 worse_query:
https://github.com/forcequitOS/worse_query

이 패치는 worse_query 자체를 새로 구현하거나 지원 경로를 확장하지 않습니다. 기존 GestaltX의 `GXCustomizationAccess.acquirePath:` 및 `worse_query_release`를 호출합니다. 원본 소스와 의존성의 라이선스·저작권 표시는 유지해야 합니다.

## 추가한 변경

1. `GXCanvasLabView.swift`: 명시적 접근 검사·적용·복원 확인을 요구하는 SwiftUI 실험 화면.
2. `GXCanvasLab.m/.h`: 고정 대상 plist의 두 canvas 키 편집, 최초 백업·상태 인증, 기기/OS 검사, 진단 로그.
3. `GXCanvasAtomic.c/.h`: 기존 파일만 대상으로 하는 임시 파일 준비·검증·원자적 교체·재읽기. Apple 메타데이터 보존은 실기기 미검증입니다.
4. `apply_patch.py`: 원본 앱 시작 화면을 추가 화면으로 연결하고 원래 두 파일을 소스 체크아웃 내 `.canvaslab-original`에 보관.
5. `BUILD_WORKFLOW.yml`: 고정 원본 커밋을 내려받아 패치를 적용하고 원본 빌드 스크립트를 실행하기 위한 사용자 저장소용 구성. 이 채팅에서 실행한 CI 결과가 아닙니다.
6. 합성 파일/소스를 사용하는 호스트 테스트, 설명서, 패키징 매니페스트.

## 라이선스

이 소스 패치의 코드는 GNU General Public License, version 3 only (`GPL-3.0-only`)로 제공합니다. 라이선스 전문은 동봉한 `LICENSE`를 보세요. 보증 없이 제공하며 상품성·특정 목적 적합성·실기기 적용 또는 복구 가능성을 보장하지 않습니다. 이 설명은 라이선스가 부여하는 권리를 제한하는 추가 조건이 아닙니다.

빌드 구성은 IPA와 함께 해당 실행의 원본+수정 소스 아티팩트를 준비하도록 되어 있습니다. 바이너리를 재배포한다면 수신자가 해당 소스를 함께 받을 수 있도록 하고, 원본 프로젝트와 의존성의 안내도 유지하세요. 이 키트만으로는 원본 프로젝트 전체 소스를 대체하지 않습니다.
