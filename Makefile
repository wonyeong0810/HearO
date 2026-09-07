.DEFAULT_GOAL := help
SHELL := /bin/bash

BACKEND := backend
APP     := app

# ---------------------------------------------------------------------------
# uv 가 있으면 쓰고, 없으면 해당 디렉터리의 .venv 로 떨어진다.
# uv 설치를 강제하지 않기 위함 — 없어도 모든 명령이 동작해야 한다.
#
# RUN 은 레시피 안에서 평가된다($$ 로 이스케이프). 이미 `cd` 한 뒤라서
# .venv 경로가 그 디렉터리 기준으로 풀린다. Windows(Git Bash)는 Scripts/,
# POSIX 는 bin/ 에 실행파일이 있어 둘 다 본다.
# ---------------------------------------------------------------------------
HAS_UV := $(shell command -v uv 2>/dev/null)

ifdef HAS_UV
  RUN := uv run
else
  RUN := $$(test -x .venv/Scripts/python.exe && echo .venv/Scripts/python.exe || echo .venv/bin/python) -m
endif

.PHONY: help
help: ## 사용 가능한 명령 목록
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------- setup
.PHONY: env
env: ## .env 생성 (없을 때만)
	@test -f .env || (cp .env.example .env && echo "→ .env 생성됨. <FILL_ME> 값을 채우세요.")

.PHONY: install
install: install-backend install-app ## 백엔드 + 앱 의존성 설치

.PHONY: install-backend
install-backend: ## 백엔드 의존성 설치 (uv 없으면 venv+pip)
	@cd $(BACKEND) && if command -v uv >/dev/null 2>&1; then uv sync --all-extras; else test -d .venv || python -m venv .venv; PY=$$(test -x .venv/Scripts/python.exe && echo .venv/Scripts/python.exe || echo .venv/bin/python); $$PY -m pip install -q --upgrade pip; $$PY -m pip install -q -e ".[dev]"; echo "설치 완료 ($$PY)"; fi

.PHONY: install-app
install-app: ## Flutter 의존성 설치
	cd $(APP) && flutter pub get

# ---------------------------------------------------------------- run
.PHONY: up
up: env ## 전체 스택 기동 (db + redis + api + worker)
	docker compose up -d --build
	@echo "→ API: http://localhost:$${API_PORT:-8000}/docs"

.PHONY: down
down: ## 스택 정지
	docker compose down

.PHONY: reset
reset: ## 스택 정지 + 볼륨 삭제 (DB 데이터 전부 삭제됨)
	docker compose down -v

.PHONY: logs
logs: ## API 로그 팔로우
	docker compose logs -f api worker

.PHONY: dev
dev: ## 백엔드를 로컬에서 핫리로드로 실행 (db/redis 는 docker)
	docker compose up -d db redis
	cd $(BACKEND) && $(RUN) uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

.PHONY: run-app
run-app: ## Flutter 앱 실행
	cd $(APP) && flutter run --dart-define-from-file=../.env.dart.json

# ---------------------------------------------------------------- db
.PHONY: migrate
migrate: ## 최신 마이그레이션 적용
	cd $(BACKEND) && $(RUN) alembic upgrade head

.PHONY: migration
migration: ## 새 마이그레이션 생성  usage: make migration m="add xyz"
	cd $(BACKEND) && $(RUN) alembic revision --autogenerate -m "$(m)"

.PHONY: downgrade
downgrade: ## 마이그레이션 1단계 롤백
	cd $(BACKEND) && $(RUN) alembic downgrade -1

# ---------------------------------------------------------------- quality
.PHONY: test
test: test-backend test-app ## 전체 테스트

.PHONY: test-backend
test-backend: ## 백엔드 테스트 + 커버리지
	cd $(BACKEND) && $(RUN) pytest -q --cov=app --cov-report=term-missing

.PHONY: test-app
test-app: ## Flutter 테스트
	cd $(APP) && flutter test

.PHONY: lint
lint: ## 정적 검사 (ruff + mypy + dart analyze)
	cd $(BACKEND) && $(RUN) ruff check . && cd $(CURDIR)/$(BACKEND) && $(RUN) mypy app
	cd $(APP) && dart analyze

.PHONY: fmt
fmt: ## 포매팅
	cd $(BACKEND) && $(RUN) ruff format . && $(RUN) ruff check --fix .
	cd $(APP) && dart format lib test

# ---------------------------------------------------------------- build
.PHONY: build-apk
build-apk: ## Android release APK
	cd $(APP) && flutter build apk --release --split-per-abi

.PHONY: build-ipa
build-ipa: ## iOS release
	cd $(APP) && flutter build ipa --release
