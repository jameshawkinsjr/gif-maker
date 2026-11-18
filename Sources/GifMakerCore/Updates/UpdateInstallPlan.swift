import Foundation

/// The last step of an update: swapping the installed app for a new copy.
///
/// An app can't replace itself while it is running, so the swap is done by a
/// small shell script that outlives the app. The script waits for the app to
/// quit, moves it aside, moves the new copy into its place and starts it. The
/// old app is only deleted once the new one has started and stayed up; if
/// anything goes wrong before that, the old app is moved back and reopened.
///
/// Both moves are renames within one folder, which is why the new copy is
/// staged beside the installed app rather than in a temporary directory.
public struct UpdateInstallPlan: Equatable, Sendable {
    /// Arguments the relaunched app is started with, so it can say what happened.
    public enum LaunchArgument {
        /// The update was installed and this is the new version's first launch.
        public static let updated = "--updated"
        /// As `updated`, and the new version's signature doesn't satisfy the old
        /// one's requirement, so macOS won't carry Screen Recording permission over.
        public static let signatureChanged = "--update-signature-changed"
        /// The update couldn't be installed and the previous version was put back.
        public static let failed = "--update-failed"
    }

    /// The running app, which the script waits for.
    public var processID: Int32
    /// The verified new app, in the same folder as `installedApp`.
    public var stagedApp: URL
    public var installedApp: URL
    /// Where the old app is kept until the new one has started.
    public var backupApp: URL
    /// The app's executable, relative to the bundle: "Contents/MacOS/GifMaker".
    public var executablePath: String
    /// Extra arguments for the new version's first launch.
    public var relaunchArguments: [String]
    /// The tool that launches an app bundle. Only tests change this.
    public var opener = "/usr/bin/open"
    /// Seconds to wait for the running app to quit before giving up.
    public var quitTimeout = 60
    /// Seconds to wait for the new version to appear after it is opened.
    public var launchTimeout = 20
    /// Seconds the new version has to stay running to count as working.
    public var settleTime = 3

    public init(
        processID: Int32, installedApp: URL, executablePath: String, relaunchArguments: [String] = []
    ) {
        self.processID = processID
        self.installedApp = installedApp
        self.stagedApp = Self.stagedURL(for: installedApp)
        self.backupApp = Self.backupURL(for: installedApp)
        self.executablePath = executablePath
        self.relaunchArguments = relaunchArguments
    }

    /// Where the new copy is put before the swap. Hidden, and without the .app
    /// extension so nothing mistakes it for a second copy of the app.
    public static func stagedURL(for installedApp: URL) -> URL {
        sibling(of: installedApp, suffix: "update")
    }

    public static func backupURL(for installedApp: URL) -> URL {
        sibling(of: installedApp, suffix: "previous")
    }

    private static func sibling(of app: URL, suffix: String) -> URL {
        app.deletingLastPathComponent().appendingPathComponent(".\(app.lastPathComponent).\(suffix)", isDirectory: true)
    }

    /// Arguments for `/bin/sh` that run the swap.
    public var shellArguments: [String] {
        [
            "-c", Self.script, "gifmaker-update",
            String(processID), stagedApp.path, installedApp.path, backupApp.path, executablePath, opener,
            String(quitTimeout), String(launchTimeout), String(settleTime),
        ] + relaunchArguments
    }

    /// What the script's exit status means.
    public enum ExitStatus {
        public static let installed: Int32 = 0
        /// The app never quit; nothing was changed.
        public static let appStillRunning: Int32 = 3
        /// The swap couldn't start; nothing was changed.
        public static let notInstalled: Int32 = 4
        /// The swap or the new version failed, and the previous version was restored.
        public static let rolledBack: Int32 = 5
        /// The previous version couldn't be moved back. It is still at `backupApp`.
        public static let restoreFailed: Int32 = 6
    }

    static let script = #"""
        pid=$1; staged=$2; installed=$3; backup=$4; executable=$5; opener=$6
        quit_timeout=$7; launch_timeout=$8; settle=$9
        shift 9

        # Nothing may cut this short halfway through the swap.
        trap '' HUP INT TERM

        log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

        # True while a process started from the installed app's executable exists.
        # The path is handed to awk through the environment so that this pipeline
        # can't match its own command line.
        is_running() {
            ps -axwwo args= | UPDATE_TARGET="$installed/$executable" UPDATE_TARGET_PHYSICAL="$physical/$executable" \
                awk 'index($0, ENVIRON["UPDATE_TARGET"]) == 1 || index($0, ENVIRON["UPDATE_TARGET_PHYSICAL"]) == 1 { found = 1 }
                     END { exit !found }'
        }

        # The new version has to appear, and then stay up rather than crash on launch.
        started() {
            ticks=$((launch_timeout * 5))
            until is_running; do
                [ "$ticks" -le 0 ] && return 1
                ticks=$((ticks - 1))
                sleep 0.2
            done
            sleep "$settle"
            is_running
        }

        reopen_previous() {
            "$opener" -n "$installed" --args \#(LaunchArgument.failed)
        }

        # Puts the previous version back where it was. Whatever is in its place is
        # moved out of the way first and only deleted once the old app is back.
        restore() {
            if [ -e "$installed" ]; then
                rm -rf "$staged"
                mv "$installed" "$staged" || rm -rf "$installed"
            fi
            if mv "$backup" "$installed"; then
                rm -rf "$staged"
                log "The previous version was restored."
                reopen_previous
                exit \#(ExitStatus.rolledBack)
            fi
            log "The previous version could not be moved back. It is at: $backup"
            exit \#(ExitStatus.restoreFailed)
        }

        log "Waiting for the app (process $pid) to quit."
        ticks=$((quit_timeout * 5))
        while kill -0 "$pid" 2>/dev/null; do
            if [ "$ticks" -le 0 ]; then
                log "The app didn't quit, so the update was not installed."
                rm -rf "$staged"
                exit \#(ExitStatus.appStillRunning)
            fi
            ticks=$((ticks - 1))
            sleep 0.2
        done

        if [ ! -d "$staged" ] || [ ! -d "$installed" ]; then
            log "The new copy or the installed app is missing, so the update was not installed."
            rm -rf "$staged"
            [ -d "$installed" ] && reopen_previous
            exit \#(ExitStatus.notInstalled)
        fi
        rm -rf "$backup"
        if [ -e "$backup" ]; then
            log "An old backup is in the way and can't be removed: $backup"
            rm -rf "$staged"
            reopen_previous
            exit \#(ExitStatus.notInstalled)
        fi

        if ! mv "$installed" "$backup"; then
            log "The installed app can't be moved, so the update was not installed."
            rm -rf "$staged"
            reopen_previous
            exit \#(ExitStatus.notInstalled)
        fi
        if [ -e "$installed" ] || ! mv "$staged" "$installed"; then
            log "The new version couldn't be moved into place."
            restore
        fi

        xattr -dr com.apple.quarantine "$installed" 2>/dev/null
        physical=$(cd "$installed" 2>/dev/null && pwd -P)

        log "Starting the new version."
        if "$opener" -n "$installed" --args \#(LaunchArgument.updated) "$@" && started; then
            log "The update was installed."
            rm -rf "$backup" || log "The previous version couldn't be deleted. It is at: $backup"
            exit \#(ExitStatus.installed)
        fi
        log "The new version didn't start."
        restore
        """#
}
