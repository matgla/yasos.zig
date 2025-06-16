CONTAINER_VERSION ?= v0.10

start_env:
	podman run --userns=keep-id -v $(shell pwd):/workspace -w /workspace -it matgla/yasos_zig_dev:${CONTAINER_VERSION}

build_container:
	podman manifest create -a matgla/yasos_zig_dev:${CONTAINER_VERSION}
	podman build --platform linux/amd64,linux/arm64 --manifest matgla/yasos_zig_dev:${CONTAINER_VERSION} . 

push_container:
	podman manifest push --all matgla/yasos_zig_dev:${CONTAINER_VERSION} ghcr.io/matgla/yasos_zig_dev:${CONTAINER_VERSION}

pull_container:
	podman pull ghcr.io/matgla/yasos_zig_dev:${CONTAINER_VERSION}

clean: 
	rm -rf zig-out .zig-cache config yasos_venv 