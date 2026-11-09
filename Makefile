CONTAINER_VERSION ?= v0.21
RUN_CONTAINER ?= ./scripts/run_container.sh -v ${CONTAINER_VERSION}

# tcc -O levels the smoke suites run at. Every suite (tests2, ir_tests,
# gcc-torture) runs once per level, so this multiplies the run; a single level
# is roughly a third of the wall time:
#   make run_smoke_tests_packaged SMOKE_OPT_LEVELS=-O0
# Comma-separated on purpose -- run_container.sh expands its --command
# unquoted, so a value with spaces would word-split into separate arguments.
SMOKE_OPT_LEVELS ?= -O0,-O1,-O2

start_env:
	${RUN_CONTAINER} -i

build_container:
	podman manifest create -a matgla/yasos.zig:${CONTAINER_VERSION}
	podman build --platform linux/amd64,linux/arm64 --manifest matgla/yasos.zig:${CONTAINER_VERSION} .

push_container:
	podman manifest push --all matgla/yasos.zig:${CONTAINER_VERSION} ghcr.io/matgla/yasos.zig:${CONTAINER_VERSION}

pull_container:
	podman pull ghcr.io/matgla/yasos.zig:${CONTAINER_VERSION}

clean:
	rm -rf zig-out .zig-cache config yasos_venv

prepare_smoke: pull_container
	${RUN_CONTAINER} -c "./tests/smoke/prepare.sh"

run_smoke_tests: prepare_smoke
	${RUN_CONTAINER} -c "./tests/smoke/run_tests.sh"

# Flash a prebuilt image (zig-out/bin/yasos_kernel + ./rootfs.img, staged from
# the build_hw CI artifact) and run the on-device smoke suite without rebuilding.
run_smoke_tests_packaged: pull_container
	${RUN_CONTAINER} -c "./scripts/run_hw_smoke.sh --opt-levels ${SMOKE_OPT_LEVELS}"

# The board builds itself (CI's hardware_selfhost / hardware_zig_kernel jobs):
# images staged as for run_smoke_tests_packaged, plus the prepared payload/package.
SELFHOST_PAYLOAD ?= selfhost_payload
ZIG_KERNEL_PACKAGE ?= zig_kernel_package

run_selfhost_packaged: pull_container
	${RUN_CONTAINER} -c "./scripts/run_hw_selfhost.sh ${SELFHOST_PAYLOAD}"

run_zig_kernel_packaged: pull_container
	${RUN_CONTAINER} -c "./scripts/run_hw_zig_kernel.sh ${ZIG_KERNEL_PACKAGE}"

run_smoke_tests_qemu: prepare_smoke
	${RUN_CONTAINER} -c "./scripts/run_qemu_smoke.sh --opt-levels ${SMOKE_OPT_LEVELS}"

run_qemu: pull_container 
	${RUN_CONTAINER} -c "./scripts/run_qemu.sh"

ut:
	$(MAKE) -C libs/tinycc/tests/unit run

run_tests:
	${RUN_CONTAINER} -c "zig build test --summary all"
	${RUN_CONTAINER} -c "zig build test -Doptimize=ReleaseFast --summary all"
