ROOT := $(abspath ..)
.PHONY: app install test
app:
	cmake -S "$(ROOT)" -B "$(ROOT)/build" -DCMAKE_BUILD_TYPE=Release
	cmake --build "$(ROOT)/build" --target kapitsa -j 6
	python3 build-app.py

install: app
	python3 build-app.py --install-only

test:
	swift test
