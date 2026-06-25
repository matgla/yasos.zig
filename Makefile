CONTAINER_VERSION ?= v0.17
RUN_CONTAINER ?= ./scripts/run_container.sh -v ${CONTAINER_VERSION}

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
	${RUN_CONTAINER} -c "./scripts/run_hw_smoke.sh"

run_smoke_tests_qemu: prepare_smoke
	${RUN_CONTAINER} -c "./scripts/run_qemu_smoke.sh"

run_qemu: pull_container 
	${RUN_CONTAINER} -c "./scripts/run_qemu.sh"

ut:
	$(MAKE) -C libs/tinycc/tests/unit run

run_tests:
	${RUN_CONTAINER} -c "zig build test --summary all"
	${RUN_CONTAINER} -c "zig build test -Doptimize=ReleaseFast --summary all"
