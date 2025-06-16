CONTAINER_VERSION ?= v0.12
RUN_CONTAINER ?= podman run --device=/dev/ttyACM0 --device=/dev/bus/usb --userns=keep-id -v $(shell pwd):/workspace -w /workspace matgla/yasos.zig:${CONTAINER_VERSION}

start_env:
	podman run --device=/dev/ttyACM0 --device=/dev/bus/usb --userns=keep-id -v $(shell pwd):/workspace -w /workspace -it matgla/yasos.zig:${CONTAINER_VERSION}

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
	${RUN_CONTAINER}  ./tests/smoke/prepare.sh

run_smoke_tests: prepare_smoke
	${RUN_CONTAINER} ./tests/smoke/run_tests.sh 

run_tests: 
	${RUN_CONTAINER} zig build test --summary all

