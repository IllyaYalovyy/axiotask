# Axiotask Flutter

Axiotask is a native Flutter client for Google Tasks on Fedora GNOME and
Android. The current S00 scaffold is intentionally a minimal launchable shell;
Google authorization, persistence, synchronization, and task workflows arrive
only in their approved later slices.

## Supported development environment

- Fedora Linux 43 or a later supported Fedora release with GNOME.
- Flutter stable `>=3.44.0 <3.45.0` (validated with `3.44.8`).
- Dart `>=3.12.0 <3.13.0` (validated with `3.12.2`).
- Android SDK 36.1, Android SDK Build-Tools 36.1, Android Platform-Tools, and
  an API 36.1 emulator or attached Android device.
- JDK 21, either Fedora OpenJDK or Android Studio's bundled JDK.

Install the Fedora build prerequisites:

```bash
sudo dnf install clang cmake ninja-build pkgconf-pkg-config gtk3-devel \
  libstdc++-devel java-21-openjdk-devel
```

Install Flutter `3.44.8` from the official Flutter archive, add its `bin`
directory to `PATH`, and use Android Studio's SDK Manager to install the Android
components above. Then verify both toolchains:

```bash
flutter config --enable-linux-desktop
flutter doctor -v
```

The Linux and Android sections of `flutter doctor -v` must pass before building.
Chrome and unsupported Apple/Windows targets are not required.

## Clean-checkout setup

```bash
git clone --branch flutter2 --single-branch \
  https://github.com/IllyaYalovyy/axiotask.git axiotask_flutter2
cd axiotask_flutter2
flutter pub get
./scripts/quality.sh
```

`pubspec.lock` is committed. Do not run a dependency upgrade as part of normal
setup.

## Linux build, local launch, and development run

Build the relocatable debug bundle and launch it directly:

```bash
flutter build linux --debug
./build/linux/x64/debug/bundle/axiotask
```

For a development session with hot reload:

```bash
flutter run -d linux --debug
```

System-wide packaging or installation is deliberately out of scope.

## Android build, local installation, and development run

Build the debug APK:

```bash
flutter build apk --debug
```

Start an Android Studio AVD or an isolated command-line emulator, then obtain
its ID:

```bash
flutter emulators
flutter emulators --launch <emulator-id>
flutter devices
```

Install the built debug APK and launch a hot-reload development session using
the device ID printed by `flutter devices`:

```bash
flutter install --debug -d <device-id>
flutter run --debug -d <device-id>
```

This scaffold does not read credentials, application storage, or Google Tasks.
Future real-service tests must use the dedicated isolated configuration defined
by the accepted testing and security documents.

## Verification

The normal fail-fast local gate is:

```bash
./scripts/quality.sh
```

It verifies formatting, strict analysis, all Flutter tests, the privacy
checker's rejection fixtures, and the repository privacy scan. Useful focused
commands are:

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze --fatal-infos --fatal-warnings
flutter test test/app_smoke_test.dart
./test/privacy_check_test.sh
./scripts/privacy_check.sh
```

There is no hosted CI, packaging workflow, or support for web, Windows, macOS,
or iOS.

## Engineering references

- [Product vision](VISION.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Vertical-slice execution plan](docs/EXECUTION_PLAN.md)
- [Testing strategy](docs/TESTING.md)
- [Security and privacy](docs/SECURITY.md)
- [Dependency decisions](docs/DEPENDENCIES.md)
