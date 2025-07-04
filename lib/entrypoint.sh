#!/bin/bash
# Removed: set -e globally, as we want to conditionally skip errors for build steps.

echo "--- Multi-Platform WebView App Builder ---"

# --- Define Paths ---
CONFIG_FILE="/config.yaml"                           # User's mounted config.yaml
DEFAULT_CONFIG_FILE="/generator/default_config.yaml" # Default config baked into image
ACTIVE_CONFIG_FILE="/generator/config.yaml"          # The config file that main.py will read

WEBAPP_ASSETS_DIR="/webapp"
OUTPUT_DIR="/output"

# Define the root directory for each platform's project within the container
CONTAINER_MULTI_PLATFORM_ROOT="/app" # This is the /app where template-app was copied

ANDROID_PROJECT_ROOT="${CONTAINER_MULTI_PLATFORM_ROOT}/android" # NEW
ANDROID_APP_SRC_MAIN_DIR="${ANDROID_PROJECT_ROOT}/app/src/main" # NEW (derived)

IOS_PROJECT_ROOT="${CONTAINER_MULTI_PLATFORM_ROOT}/ios"         # Placeholder (changed to ios_project for consistency with windows_project)
LINUX_PROJECT_ROOT="${CONTAINER_MULTI_PLATFORM_ROOT}/linux"     # Placeholder (changed to linux_project)
WINDOWS_PROJECT_ROOT="${CONTAINER_MULTI_PLATFORM_ROOT}/windows" # Placeholder (changed to windows_project)
MACOS_PROJECT_ROOT="${CONTAINER_MULTI_PLATFORM_ROOT}/macos"     # Placeholder (changed to macos_project)

GENERATOR_DIR="/generator"

# --- Parse Command-Line Arguments ---
PLATFORM=""
SKIP_ERRORS="false" # Default to false: script exits on first build failure

while getopts ":p:s" opt; do # Added 's' for -s (skip errors)
    case $opt in
    p)
        PLATFORM="$OPTARG"
        ;;
    s) # New argument for skipping errors
        SKIP_ERRORS="true"
        echo "⚠️  Skip errors mode enabled. Build failures for individual platforms will be logged, but the process will continue."
        ;;
    \?)
        echo "❌ Error: Invalid option: -$OPTARG" >&2
        exit 1
        ;;
    :)
        echo "❌ Error: Option -$OPTARG requires an argument." >&2
        exit 1
        ;;
    esac
done
shift $((OPTIND - 1))

# --- Validate PLATFORM Argument ---
if [ -z "$PLATFORM" ]; then
    echo "❌ Error: -p <platform> argument is required."
    echo "Usage: docker run <your-image-name> -p <all|android|ios|linux|windows|macos> [-s]" # Updated usage
    exit 1
fi

case "$PLATFORM" in
"all" | "android" | "ios" | "linux" | "windows" | "macos")
    echo "✅ Building for platform(s): $PLATFORM"
    ;;
*)
    echo "❌ Error: Invalid platform '$PLATFORM'. Must be 'all', 'android', 'ios', 'linux', 'windows', or 'macos'."
    exit 1
    ;;
esac

# --- Configure the ACTIVE config.yaml for the generator ---
echo "⚙️  Preparing active configuration file..."
# This step is critical and *must* succeed, so we use '|| exit 1'
python3 -c "
import yaml
import sys
import os

def merge_configs(base, new):
    for k, v in new.items():
        if k in base and isinstance(base[k], dict) and isinstance(v, dict):
            base[k] = merge_configs(base[k], v)
        else:
            base[k] = v
    return base

try:
    default_config_file = os.environ.get('DEFAULT_CONFIG_FILE', '${DEFAULT_CONFIG_FILE}')
    config_file = os.environ.get('CONFIG_FILE', '${CONFIG_FILE}')
    active_config_file = os.environ.get('ACTIVE_CONFIG_FILE', '${ACTIVE_CONFIG_FILE}')

    with open(default_config_file, 'r', encoding='utf-8') as f:
        default_conf = yaml.safe_load(f) or {}

    user_conf = {}
    # Only try to open config_file if it actually exists to prevent FileNotFoundError
    if os.path.exists(config_file):
        with open(config_file, 'r', encoding='utf-8') as f:
            user_conf = yaml.safe_load(f) or {}

    final_conf = merge_configs(default_conf, user_conf)
    with open(active_config_file, 'w', encoding='utf-8') as f:
        yaml.dump(final_conf, f, default_flow_style=False)
    print('Merged config written to ' + active_config_file)
except Exception as e:
    print(f'Error during config merge: {e}', file=sys.stderr)
    sys.exit(1)
" DEFAULT_CONFIG_FILE="$DEFAULT_CONFIG_FILE" CONFIG_FILE="$CONFIG_FILE" ACTIVE_CONFIG_FILE="$ACTIVE_CONFIG_FILE" || {
    echo "❌ Failed to merge configurations."
    exit 1
}

# --- Conditional Static Asset Copy (if any platform uses local assets) ---
# This still uses the top-level `url` to decide if /webapp should be copied.
# If different platforms use different asset sources, this logic will need to be refined.
APP_URL_FROM_CONFIG=$(python3 -c "import sys, yaml; config=yaml.safe_load(sys.stdin); print(config.get('url'))" <"$ACTIVE_CONFIG_FILE")
APP_NAME=$(python3 -c "import sys, yaml; config=yaml.safe_load(sys.stdin); print(config.get('app_name'))" <"$ACTIVE_CONFIG_FILE")

# This is placed here as a general asset copy step if *any* platform needs it.
# The destination here is primarily Android-centric for now.
# Future: This needs to be smarter based on platform, or assets are copied by platform modifiers.
if [[ "$APP_URL_FROM_CONFIG" == file:///android_asset/* ]] && [[ "$PLATFORM" == "all" || "$PLATFORM" == "android" ]]; then
    echo "📂 App URL indicates local assets. Copying static files from ${WEBAPP_ASSETS_DIR} to ${ANDROID_APP_SRC_MAIN_DIR}/assets..."
    mkdir -p "${ANDROID_APP_SRC_MAIN_DIR}/assets" || {
        echo "❌ Failed to create Android assets directory."
        exit 1
    }
    if [ -d "$WEBAPP_ASSETS_DIR" ] && [ "$(ls -A $WEBAPP_ASSETS_DIR)" ]; then
        cp -r "${WEBAPP_ASSETS_DIR}/." "${ANDROID_APP_SRC_MAIN_DIR}/assets" || {
            echo "❌ Failed to copy Android static assets."
            exit 1
        }
        echo "✅ Static assets copied for local WebView use (to Android assets)."
    else
        echo "⚠️ No static assets found in ${WEBAPP_ASSETS_DIR}. WebView might show a blank page."
    fi
else
    echo "🌐 App URL is external or not an Android build. Skipping general static asset copy to Android assets."
fi

# Buildtypes specifications
# NEW: Read build_type from the merged config.yaml
ANDROID_BUILD_TYPE=$(python3 -c "import sys, yaml; config=yaml.safe_load(sys.stdin); print(config.get('build_settings', {}).get('default_build_type', 'debug'))" <"$ACTIVE_CONFIG_FILE")
echo "✅ Build type read from config.yaml: $ANDROID_BUILD_TYPE"

# --- Run Python Generator (Pass platform and project roots) ---
echo "🔧 Running Python generator to configure app for platform(s): $PLATFORM..."
# This step is critical and *must* succeed, so we use '|| exit 1'
python3 "${GENERATOR_DIR}/main.py" \
    "${ANDROID_PROJECT_ROOT}" \
    "${IOS_PROJECT_ROOT}" \
    "${LINUX_PROJECT_ROOT}" \
    "${WINDOWS_PROJECT_ROOT}" \
    "${MACOS_PROJECT_ROOT}" \
    "${WEBAPP_ASSETS_DIR}" \
    "${CONTAINER_MULTI_PLATFORM_ROOT}" \
    "$PLATFORM" ||
    {
        echo "❌ Python generator failed. Check Python logs above."
        exit 1
    }

# --- Conditional Build Steps ---

# Android Build
if [[ "$PLATFORM" == "all" || "$PLATFORM" == "android" ]]; then
    # Read Android-specific build type
    ANDROID_BUILD_TYPE=$(python3 -c "import sys, yaml; config=yaml.safe_load(sys.stdin); print(config.get('platform_config', {}).get('android', {}).get('build', {}).get('build_type', 'debug'))" <"$ACTIVE_CONFIG_FILE")
    echo "📦 Building Android APK (Type: $ANDROID_BUILD_TYPE)..."
    cd "${ANDROID_PROJECT_ROOT}" || {
        echo "❌ Failed to change directory to ${ANDROID_PROJECT_ROOT}. Current WD: $(pwd)"
        exit 1
    }
    cat app/build.gradle

    echo "🔍 Verifying gradlew existence and permissions at $(pwd)/gradlew..."
    if [ ! -f "./gradlew" ]; then
        echo "❌ gradlew file NOT FOUND at $(pwd)/gradlew. Please ensure template-app/android contains gradlew."
        ls -l . # List current directory contents
        exit 1
    fi
    if [ ! -x "./gradlew" ]; then
        echo "❌ gradlew is NOT EXECUTABLE at $(pwd)/gradlew. Trying to set permissions again."
        chmod +x "./gradlew" || {
            echo "❌ Failed to make gradlew executable."
            exit 1
        }
    fi
    echo "✅ gradlew found and is executable."

    echo "🚀 Starting actual Gradle build (Build Type: $ANDROID_BUILD_TYPE)..."
    ./gradlew assemble${ANDROID_BUILD_TYPE^} # Uses Android-specific build type
    BUILD_STATUS=$?

    if [ $BUILD_STATUS -ne 0 ]; then
        echo "❌ Gradle build FAILED for Android."
        if [ "$SKIP_ERRORS" = "true" ]; then
            echo "⚠️  Skipping Android build errors as requested. Continuing with other platforms if applicable."
        else
            echo "🛑 Exiting due to Android build failure. Run with '-s' to skip errors."
            exit 1
        fi
    else
        echo "✅ Android Gradle build successful."
        echo "✅ Exporting Android APK..."
        mkdir -p "$OUTPUT_DIR" || {
            echo "❌ Failed to create output directory."
            exit 1
        }

        APK_PATH=$(find "${ANDROID_PROJECT_ROOT}/app/build/outputs/apk/$ANDROID_BUILD_TYPE" -name "*.apk" -print -quit)

        if [ -f "$APK_PATH" ]; then
            APK_FILENAME=$(basename "$APK_PATH")
            cp -fv "$APK_PATH" "$OUTPUT_DIR/$APK_FILENAME" || {
                echo "❌ Failed to copy Android APK to output."
                exit 1
            }
            echo "🎉 Done! Android APK available at /output/$APK_FILENAME"
        else
            echo "❌ Failed to find Android APK. Check Gradle build logs for errors."
            ls -lR "${ANDROID_PROJECT_ROOT}/app/build/outputs/apk/$ANDROID_BUILD_TYPE"
            if [ "$SKIP_ERRORS" = "true" ]; then
                echo "⚠️  Skipping artifact export error for Android."
            else
                exit 1
            fi
        fi
    fi
else
    echo "ℹ️ Skipping Android build as platform is not 'all' or 'android'."
fi

# iOS Build (Placeholder)
if [[ "$PLATFORM" == "all" || "$PLATFORM" == "ios" ]]; then
    # Read iOS-specific build type (placeholder)
    IOS_BUILD_TYPE=$(python3 -c "import sys, yaml; config=yaml.safe_load(sys.stdin); print(config.get('platform_config', {}).get('ios', {}).get('build', {}).get('build_type', 'debug'))" <"$ACTIVE_CONFIG_FILE")
    echo "--- iOS Build (Placeholder) (Type: $IOS_BUILD_TYPE) ---"
    echo "💡 As noted in the Dockerfile, iOS builds require Xcode on a macOS environment."
    echo "   This Linux Docker image cannot build for iOS."
    echo "--- iOS Build Placeholder Complete ---"
fi

# Linux Desktop Build (Placeholder)
if [[ "$PLATFORM" == "all" || "$PLATFORM" == "linux" ]]; then
    # Read Linux-specific build type (placeholder)
    LINUX_BUILD_TYPE=$(python3 -c "import sys, yaml; config=yaml.safe_load(sys.stdin); print(config.get('platform_config', {}).get('linux', {}).get('build', {}).get('build_type', 'debug'))" <"$ACTIVE_CONFIG_FILE")
    echo "--- Linux Desktop Build (Placeholder) (Type: $LINUX_BUILD_TYPE) ---"
    echo "💡 Node.js and Rust are installed. You can add build commands here for frameworks like Electron or Tauri."
    echo "--- Linux Desktop Build Placeholder Complete ---"
fi

# Windows Desktop Build
if [[ "$PLATFORM" == "all" || "$PLATFORM" == "windows" ]]; then
    WAILS_BUILD_TYPE=$(python3 -c "import sys, yaml; config=yaml.safe_load(sys.stdin); print(config.get('platform_config', {}).get('wails', {}).get('build', {}).get('build_type', 'debug'))" <"$ACTIVE_CONFIG_FILE")

    echo "--- Wails Build (Type: $WAILS_BUILD_TYPE, Target OS: $WAILS_TARGET_OS) ---"
    WAILS_PROJECT_ROOT=$WINDOWS_PROJECT_ROOT/go_app
    if [ ! -d "$WAILS_PROJECT_ROOT" ]; then
        echo "❌ Wails project directory not found: ${WAILS_PROJECT_ROOT}."
        echo "Please ensure 'template-app/wails_project' exists on your host and contains a Wails project."
        exit 1
    fi

    cd "$WAILS_PROJECT_ROOT" || {
        echo "❌ Failed to change directory to ${WAILS_PROJECT_ROOT}."
        exit 1
    }

    echo "📦 Initializing Wails dependencies and ensuring clean Go environment..."
    # Ensure any lingering GOOS/GOARCH from previous steps are unset for Wails's own internal tools
    # Wails manages its own cross-compilation.
    unset GOOS
    unset GOARCH

    # Run 'go mod tidy' explicitly within the Wails project context
    # This ensures dependencies are correct before Wails tries to build its internal tools.
    go mod tidy
    GO_MOD_STATUS=$?
    if [ $GO_MOD_STATUS -ne 0 ]; then
        echo "❌ 'go mod tidy' FAILED in Wails project. Please check Go module configuration."
        if [ "$SKIP_ERRORS" = "true" ]; then
            echo "⚠️  Skipping Wails build errors."
        else
            exit 1
        fi
    else
        echo "✅ 'go mod tidy' successful in Wails project."
    fi

    WAILS_BUILD_CMD="wails build -o ${APP_NAME}.exe"

    # Add build type flag
    if [[ "$WAILS_BUILD_TYPE" == "release" ]]; then
        WAILS_BUILD_CMD="${WAILS_BUILD_CMD} -p" # -p for production build
    fi

    echo "🚀 Running Wails build command: ${WAILS_BUILD_CMD}"
    GOOS=windows GOARCH=amd64 ${WAILS_BUILD_CMD} -skipbindings
    BUILD_STATUS=$?

    if [ $BUILD_STATUS -ne 0 ]; then
        echo "❌ Wails build FAILED."
        if [ "$SKIP_ERRORS" = "true" ]; then
            echo "⚠️  Skipping Wails build errors as requested."
        else
            exit 1
        fi
    else
        echo "✅ Wails build successful."
        echo "✅ Exporting Wails App..."
        mkdir -p "$OUTPUT_DIR" || {
            echo "❌ Failed to create output directory."
            exit 1
        }

        APP_NAME_FROM_CONFIG=$(python3 -c "import sys, yaml; config=yaml.safe_load(sys.stdin); print(config.get('app_name', 'default-app'))" <"$ACTIVE_CONFIG_FILE")

        ARTIFACT_FILENAME=$(basename "$WAILS_ARTIFACT_PATH")
        cp -rfv "$WAILS_PROJECT_ROOT/build/bin" "$OUTPUT_DIR" || {
            echo "❌ Failed to copy Wails App artifact to output."
            exit 1
        }
        echo "🎉 Done! Wails App artifact available at /output"

        # if [ -f "$WAILS_ARTIFACT_PATH" ]; then
        # else
        #     echo "❌ Failed to find Wails App artifact after build. Check Wails build logs for errors. Expected in: ${WAILS_ARTIFACT_FINAL_DIR}"
        #     ls -lR # List contents for debugging
        #     if [ "$SKIP_ERRORS" = "true" ]; then
        #         echo "⚠️  Skipping artifact export error for Wails."
        #     else
        #         exit 1
        #     fi
        # fi
    fi
    echo "--- Wails Build Complete ---"
else
    echo "ℹ️ Skipping Windows build as platform is not 'all' or 'windows'."
fi

# macOS Desktop Build (Placeholder)
if [[ "$PLATFORM" == "all" || "$PLATFORM" == "macos" ]]; then
    echo "--- macOS Desktop Build (Placeholder) ---"
    echo "💡 As noted in the Dockerfile, macOS builds require Xcode on a macOS environment."
    echo "   This Linux Docker image cannot build for macOS."
    # Add conditional error handling here if you implement macOS build later
    # false # Uncomment to simulate failure
    # BUILD_STATUS=$?
    # if [ $BUILD_STATUS -ne 0 ]; then
    #     echo "❌ macOS build FAILED (placeholder)."
    #     if [ "$SKIP_ERRORS" = "true" ]; then echo "⚠️  Skipping macOS errors."; else exit 1; fi
    # fi
    echo "--- macOS Desktop Build Placeholder Complete ---"
fi

echo "--- Build Process Complete ---"
