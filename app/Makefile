ROOT := $(abspath ..)
BUNDLE := $(ROOT)/build/Kapitsa.app
CONTENTS := $(BUNDLE)/Contents

.PHONY: app test
app:
	cmake -S "$(ROOT)" -B "$(ROOT)/build" -DCMAKE_BUILD_TYPE=Release
	cmake --build "$(ROOT)/build" --target kapitsa -j 6
	swift build -c release
	mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	cp .build/release/KapitsaApp "$(CONTENTS)/MacOS/KapitsaApp"
	cp "$(ROOT)/build/kapitsa-runtime" "$(CONTENTS)/MacOS/kapitsa-runtime"
	cp "$(ROOT)/build/kapitsa" "$(CONTENTS)/MacOS/kapitsa"
	cp Info.plist "$(CONTENTS)/Info.plist"
	swift make-icon.swift "$(CONTENTS)/Resources/Kapitsa.icns"
	cp "$(ROOT)/LICENSE" "$(ROOT)/THIRD_PARTY_NOTICES" "$(CONTENTS)/Resources/"
	codesign --force --sign - "$(CONTENTS)/MacOS/kapitsa-runtime"
	codesign --force --sign - "$(CONTENTS)/MacOS/kapitsa"
	codesign --force --sign - "$(BUNDLE)"
	@echo "Built $(BUNDLE)"

test:
	swift test
