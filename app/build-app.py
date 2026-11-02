#!/usr/bin/env python3
"""Build the app and WidgetKit extension with Xcode, then sign and publish atomically."""
import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
from pathlib import Path

APP = Path(__file__).resolve().parent
ROOT = APP.parent
BUILD = ROOT / "build/native-app"
BRAND = ROOT / "docs/assets/brand"
BRAND_ASSETS = ["kapitsa-icon-1024.png", "kapitsa-mark-1024.png", "kapitsa-mark-light-1024.png",
                "kapitsa-logo-dark-1024.png", "kapitsa-logo-light-1024.png"]
LSREGISTER = ("/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/"
              "LaunchServices.framework/Versions/Current/Support/lsregister")
WIDGET = Path("Contents/PlugIns/KapitsaWidget.appex")


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def signing():
    identity = os.environ.get("SIGN_IDENTITY", "")
    team = os.environ.get("TEAM_ID", "")
    if not identity:
        identities = run("security", "find-identity", "-v", "-p", "codesigning",
                         capture_output=True, text=True).stdout
        match = re.search(r'"(Apple Development:[^"]+)"', identities)
        identity = match[1] if match else "-"
    if identity != "-" and not team:
        cert = run("security", "find-certificate", "-c", identity, "-p", capture_output=True).stdout
        subject = run("openssl", "x509", "-noout", "-subject", input=cert,
                      capture_output=True).stdout.decode()
        match = re.search(r"(?:/|,\s*)OU\s*=\s*([A-Z0-9]+)", subject)
        if not match:
            raise SystemExit("Set TEAM_ID for the selected signing identity.")
        team = match[1]
    group = os.environ.get("APP_GROUP", f"{team}.io.github.edjubert.kapitsa" if team else
                           "group.io.github.edjubert.kapitsa")
    return identity, team, group


def project(identity, team):
    # Native Xcode targets ensure both executables receive AppIntents metadata.
    # Generated project/build products stay outside the source tree.
    objects = {}

    def obj(kind, **fields):
        identifier = f"{len(objects) + 1:024X}"
        objects[identifier] = {"isa": kind, **fields}
        return identifier

    def config(settings):
        value = obj("XCBuildConfiguration", name="Release", buildSettings=settings)
        return obj("XCConfigurationList", buildConfigurations=[value],
                   defaultConfigurationIsVisible="0", defaultConfigurationName="Release")

    shared = sorted((APP / "Shared").glob("*.swift"))
    app_files = sorted((APP / "Sources/KapitsaApp").glob("*.swift")) + shared
    widget_files = [APP / "Widget/KapitsaWidget.swift",
                    APP / "Sources/KapitsaApp/RuntimeClient.swift"] + shared
    references = {}
    for path in dict.fromkeys(app_files + widget_files):
        references[path] = obj("PBXFileReference", lastKnownFileType="sourcecode.swift",
                               path=str(path), sourceTree="<absolute>")
    products = []
    targets = []
    for name, files, suffix, product_type in [
        ("Kapitsa", app_files, "app", "com.apple.product-type.application"),
        ("KapitsaWidget", widget_files, "appex", "com.apple.product-type.app-extension"),
    ]:
        product = obj("PBXFileReference", explicitFileType="wrapper.application" if suffix == "app"
                      else "wrapper.app-extension", path=f"{name}.{suffix}",
                      sourceTree="BUILT_PRODUCTS_DIR")
        products.append(product)
        phase = obj("PBXSourcesBuildPhase", buildActionMask="2147483647",
                    files=[obj("PBXBuildFile", fileRef=references[path]) for path in files],
                    runOnlyForDeploymentPostprocessing="0")
        settings = {
            "PRODUCT_NAME": name,
            "PRODUCT_BUNDLE_IDENTIFIER": "io.github.edjubert.kapitsa" +
                (".widget" if suffix == "appex" else ""),
            "INFOPLIST_FILE": str(APP / ("Widget/Info.plist" if suffix == "appex" else "Info.plist")),
            "EXECUTABLE_NAME": name if suffix == "appex" else "KapitsaApp",
            "CODE_SIGNING_ALLOWED": "NO",
            "SWIFT_VERSION": "5.0",
            "MACOSX_DEPLOYMENT_TARGET": "14.0",
            "SDKROOT": "macosx",
            "ARCHS": "arm64",
            "SWIFT_OPTIMIZATION_LEVEL": "-O",
            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks",
            "GENERATE_INFOPLIST_FILE": "NO",
            "ALWAYS_SEARCH_USER_PATHS": "NO",
            "REGISTER_APP_WITH_LAUNCH_SERVICES": "NO",
        }
        if suffix == "appex":
            settings.update(APPLICATION_EXTENSION_API_ONLY="YES", SKIP_INSTALL="YES",
                            SWIFT_ACTIVE_COMPILATION_CONDITIONS="KAPITSA_WIDGET")
        if identity != "-":
            settings.update(CODE_SIGNING_ALLOWED="YES", CODE_SIGN_STYLE="Automatic",
                DEVELOPMENT_TEAM=team, CODE_SIGN_IDENTITY=identity.split(":")[0],
                ENABLE_HARDENED_RUNTIME="YES",
                CODE_SIGN_ENTITLEMENTS=str(APP / ("Widget/KapitsaWidget.entitlements"
                    if suffix == "appex" else "Kapitsa.entitlements")))
        targets.append(obj("PBXNativeTarget", name=name, productName=name, productReference=product,
                           productType=product_type, buildConfigurationList=config(settings),
                           buildPhases=[phase], buildRules=[], dependencies=[]))
    # Embedding is part of the native app target, so Xcode's metadata extraction
    # sees the extension and can associate its intents with the containing app.
    proxy = obj("PBXContainerItemProxy", proxyType="1",
                remoteGlobalIDString=targets[1], remoteInfo="KapitsaWidget")
    dependency = obj("PBXTargetDependency", target=targets[1], targetProxy=proxy)
    embed = obj("PBXCopyFilesBuildPhase", buildActionMask="2147483647", dstPath="",
                dstSubfolderSpec="13", name="Embed App Extensions",
                files=[obj("PBXBuildFile", fileRef=products[1],
                           settings={"ATTRIBUTES": ["RemoveHeadersOnCopy", "CodeSignOnCopy"]})],
                runOnlyForDeploymentPostprocessing="0")
    objects[targets[0]]["dependencies"].append(dependency)
    objects[targets[0]]["buildPhases"].append(embed)
    products_group = obj("PBXGroup", name="Products", children=products, sourceTree="<group>")
    main_group = obj("PBXGroup", children=list(references.values()) + [products_group],
                     sourceTree="<group>")
    root = obj("PBXProject", attributes={"LastUpgradeCheck": "2600"},
               buildConfigurationList=config({}), compatibilityVersion="Xcode 14.0",
               developmentRegion="en", knownRegions=["en", "fr", "Base"], mainGroup=main_group,
               productRefGroup=products_group, projectDirPath="", projectRoot="", targets=targets)
    objects[proxy]["containerPortal"] = root
    directory = BUILD / "Kapitsa.xcodeproj"
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "project.pbxproj").write_bytes(plistlib.dumps(
        {"archiveVersion": "1", "classes": {}, "objectVersion": "56",
         "objects": objects, "rootObject": root}))
    return directory


def main():
    identity, team, group = signing()
    BUILD.mkdir(parents=True, exist_ok=True)
    counter = BUILD / "build-number"
    previous_number = int(counter.read_text()) if counter.exists() else 3
    number = os.environ.get("BUILD_NUMBER", str(previous_number + 1))
    if not re.fullmatch(r"[1-9][0-9]{0,3}", number):
        raise SystemExit("BUILD_NUMBER must be a positive integer with at most four digits.")
    counter.write_text(str(max(previous_number, int(number))))
    output = BUILD / "products"
    run("xcodebuild", "-project", str(project(identity, team)), "-alltargets", "-parallelizeTargets",
        "-configuration", "Release",
        f"CONFIGURATION_BUILD_DIR={output}", f"KAPITSA_APP_GROUP={group}",
        f"CURRENT_PROJECT_VERSION={number}", "build")
    bundle = output / "Kapitsa.app"
    contents = bundle / "Contents"
    extension = contents / "PlugIns/KapitsaWidget.appex"
    for name in ["kapitsa-runtime", "kapitsa"]:
        shutil.copy2(ROOT / "build" / name, contents / "MacOS" / name)
        run("codesign", "--force", "--sign", identity, str(contents / "MacOS" / name))
    resources = contents / "Resources"
    resources.mkdir(exist_ok=True)
    run("swift", str(APP / "make-icon.swift"), str(resources / "Kapitsa.icns"),
        str(BRAND / "kapitsa-icon-1024.png"))
    for target in [bundle, extension]:
        brand_resources = target / "Contents/Resources/Brand"
        brand_resources.mkdir(parents=True, exist_ok=True)
        for name in BRAND_ASSETS:
            shutil.copy2(BRAND / name, brand_resources / name)
    shutil.copy2(resources / "Kapitsa.icns", extension / "Contents/Resources/Kapitsa.icns")
    for name in ["LICENSE", "THIRD_PARTY_NOTICES"]:
        shutil.copy2(ROOT / name, resources / name)
    for target, template in [(extension, APP / "Widget/KapitsaWidget.entitlements"),
                             (bundle, APP / "Kapitsa.entitlements")]:
        if identity != "-":
            # Keep the native Xcode development/distribution entitlements.
            run("codesign", "--force", "--sign", identity,
                "--preserve-metadata=entitlements,flags,requirements,runtime", str(target))
        else:
            entitlements = BUILD / f"{target.stem}.entitlements"
            entitlements.write_text(template.read_text().replace("$(KAPITSA_APP_GROUP)", group))
            run("codesign", "--force", "--sign", identity, "--entitlements", str(entitlements), str(target))
    run("codesign", "--verify", "--deep", "--strict", str(bundle))
    # Never truncate a signed helper that an existing instance is executing.
    destination = ROOT / "build/Kapitsa.app"
    previous = ROOT / "build/Kapitsa.previous.app"
    if previous.exists():
        shutil.rmtree(previous)
    if destination.exists():
        destination.rename(previous)
    bundle.rename(destination)
    print(f"Built {destination} (signing: {identity}, App Group: {group})")
    if identity == "-":
        print("WidgetKit activation requires an Apple signing identity; see docs/native-app.md.")


def register(bundle):
    run(LSREGISTER, "-f", "-R", str(bundle))
    run("pluginkit", "-a", str(bundle / WIDGET))


def registered_widget_bundles():
    # Include other checkouts: opening a development bundle registers it too.
    result = run("pluginkit", "-m", "-A", "-D", "-v", "-i", "io.github.edjubert.kapitsa.widget",
                 capture_output=True, text=True)
    bundles = set()
    for line in result.stdout.splitlines():
        path = line.rpartition("\t")[2]
        if not path.startswith("/"):
            continue
        extension = Path(path)
        bundle = extension.parent.parent.parent
        if extension != bundle / WIDGET:
            continue
        try:
            app_info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
            widget_info = plistlib.loads((extension / "Contents/Info.plist").read_bytes())
        except (OSError, ValueError, plistlib.InvalidFileException):
            continue
        if (app_info.get("CFBundleIdentifier") == "io.github.edjubert.kapitsa" and
                widget_info.get("CFBundleIdentifier") == "io.github.edjubert.kapitsa.widget"):
            bundles.add(bundle.resolve())
    return bundles


def stop_widget_processes(bundles):
    # Reopening the app does not replace an already running extension. Its old
    # build number makes WidgetKit reject timelines from the updated bundle.
    executables = {(bundle / WIDGET / "Contents/MacOS/KapitsaWidget").resolve() for bundle in bundles}
    processes = run("ps", "-U", str(os.getuid()), "-o", "pid=,comm=",
                    capture_output=True, text=True)
    for line in processes.stdout.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and Path(fields[1]).resolve() in executables:
            try:
                os.kill(int(fields[0]), signal.SIGTERM)
            except ProcessLookupError:
                pass


def install():
    default = Path("/Applications") if os.access("/Applications", os.W_OK) else Path.home() / "Applications"
    destination = Path(os.environ.get("INSTALL_DIR", default)).expanduser() / "Kapitsa.app"
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        info = plistlib.loads((destination / "Contents/Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != "io.github.edjubert.kapitsa":
            raise SystemExit(f"Another Kapitsa app exists at {destination}; it was not replaced.")
    temporary = destination.parent / ".Kapitsa.installing.app"
    previous = destination.parent / ".Kapitsa.previous.app"
    if temporary.exists():
        shutil.rmtree(temporary)
    shutil.copytree(ROOT / "build/Kapitsa.app", temporary)
    run("codesign", "--verify", "--deep", "--strict", str(temporary))
    copies = registered_widget_bundles() | {
        (ROOT / "build/Kapitsa.app").resolve(),
        (ROOT / "build/Kapitsa.previous.app").resolve(), previous.resolve(),
    }
    if previous.exists():
        shutil.rmtree(previous)
    if destination.exists():
        destination.rename(previous)
    temporary.rename(destination)
    stop_widget_processes(copies | {destination.resolve()})
    # Keep build/backup copies out of WidgetKit's candidate set. Matching
    # bundle IDs with different versions can invalidate archived timelines.
    for copy in sorted(copies):
        if copy.exists() and copy != destination.resolve():
            subprocess.run([LSREGISTER, "-u", str(copy)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["pluginkit", "-r", str(copy / WIDGET)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    register(destination)
    print(f"Installed {destination}. Reopen the app after an update.")


if __name__ == "__main__":
    if sys.argv[1:] == ["--install-only"]:
        install()
    elif not sys.argv[1:]:
        main()
    else:
        raise SystemExit("Usage: build-app.py [--install-only]")
