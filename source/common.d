module common;

import core.sys.windows.windows: CommandLineToArgvW, GetCommandLineW, CreateProcessW, MessageBox,
    MB_ICONERROR, MB_ICONWARNING, MB_YESNO, IDYES, MB_OK, HWND, DETACHED_PROCESS, CREATE_UNICODE_ENVIRONMENT, STARTUPINFO_W, PROCESS_INFORMATION;
import std.string: strip, splitLines, indexOf, indexOfAny, stripLeft, replace, endsWith;
import std.windows.registry: Registry, RegistryException, Key, REGSAM;
import std.file: FileException, exists, readText, thisExePath;
import std.path: isValidFilename, buildPath, dirName;
import std.process: browse, ProcessException;
import std.net.curl: get, CurlException;
import std.typecons: Tuple, tuple;
import std.utf: toUTF16z, toUTFz;
import std.uri: encodeComponent;
import std.algorithm: canFind;
import std.format: format;
import std.range: repeat;
import std.array: join;
import std.conv: to;

import locale: Translator;

debug import std.stdio: writeln;

/// File name of the executable to download and run to install an update.
enum string SETUP_FILENAME = "SearchDeflector-Installer.exe";
/// Repository path information for Search Deflector, https://github.com/spikespaz/search-deflector.
enum string PROJECT_AUTHOR = "spikespaz";
enum string PROJECT_NAME = "search-deflector"; /// ditto
/// Current version of the Search Deflector binaries.
enum string PROJECT_VERSION = import("version.txt");
/// Online version of the engine templates that will be accessed when internet is available.
enum string ENGINE_TEMPLATES_URL = "https://raw.githubusercontent.com/spikespaz/search-deflector/release/libs/engines.txt";
/// String of the GitHub issue template.
enum string ISSUE_TEMPLATE = import("issue.md");

/// URL of the Search Deflector Wiki home page.
enum string WIKI_URL = "https://github.com/spikespaz/search-deflector/wiki";
/// URL of the wiki's thank-you page.
enum string WIKI_THANKS_URL = WIKI_URL ~ "/Thanks-for-using-Search-Deflector!";


/// Struct representing the settings to use for deflection.
static struct DeflectorSettings {
    static string engineURL; /// ditto
    static string browserPath; /// ditto
    static bool useProfile; /// Flag to enable or disable launching the browser with a profile.
    static string profileName; /// The name of the user profile to pass to the browser on launch.
    static string interfaceLanguage; /// The language code to use for the UI.
    static uint searchCount; /// Counter for how many times the user has made a search query.
    static bool disableNag; /// Flag to disable the reditection to the nag message.

    static this() {
        Key deflectorKey = Registry.currentUser.getKey("SOFTWARE\\Clients\\SearchDeflector", REGSAM.KEY_READ);
        bool anyFailed = false;

        try
            engineURL = deflectorKey.getValue("EngineURL").value_SZ;
        catch (RegistryException) {
            debug writeln("Failed to load 'EngineURL' from registry. Setting the default value.");
            anyFailed = true;
            engineURL = "google.com/search?q={{query}}";
        }

        try
            browserPath = deflectorKey.getValue("BrowserPath").value_SZ;
        catch (RegistryException) {
            debug writeln("Failed to load 'EngineURL' from registry. Setting the default value.");
            anyFailed = true;
            browserPath = "";
        }

        try
            useProfile = cast(bool) deflectorKey.getValue("UseProfile").value_DWORD;
        catch (RegistryException) {
            debug writeln("Failed to load 'EngineURL' from registry. Setting the default value.");
            anyFailed = true;
            useProfile = false;
        }

        try
            profileName = deflectorKey.getValue("ProfileName").value_SZ;
        catch (RegistryException) {
            debug writeln("Failed to load 'EngineURL' from registry. Setting the default value.");
            anyFailed = true;
            profileName = "";
        }

        try
            interfaceLanguage = deflectorKey.getValue("InterfaceLanguage").value_SZ;
        catch (RegistryException) {
            debug writeln("Failed to load 'EngineURL' from registry. Setting the default value.");
            anyFailed = true;
            interfaceLanguage = "";
        }

        try
            searchCount = deflectorKey.getValue("SearchCount").value_DWORD;
        catch (RegistryException) {
            debug writeln("Failed to load 'EngineURL' from registry. Setting the default value.");
            anyFailed = true;
            searchCount = 0;
        }

        try
            disableNag = cast(bool) deflectorKey.getValue("DisableNag").value_DWORD;
        catch (RegistryException) {
            debug writeln("Failed to load 'EngineURL' from registry. Setting the default value.");
            anyFailed = true;
            disableNag= false;
        }

        if (anyFailed) {
            debug writeln("Some values from registry did not exist, dumping new defaults.");
            dump();
        } else
            debug writeln("Successfully loaded all registry settings!");
    }

    /// Dump current settings to system registry
    static void dump() {
        Key deflectorKey = Registry.currentUser.createKey("SOFTWARE\\Clients\\SearchDeflector", REGSAM.KEY_WRITE);

        // Write necessary changes.
        deflectorKey.setValue("EngineURL", engineURL);
        deflectorKey.setValue("BrowserPath", browserPath);
        deflectorKey.setValue("SearchCount", searchCount);
        deflectorKey.setValue("UseProfile", useProfile);
        deflectorKey.setValue("ProfileName", profileName);
        deflectorKey.setValue("InterfaceLanguage", interfaceLanguage);
        deflectorKey.setValue("DisableNag", disableNag);

        deflectorKey.flush();
    }
}

/// Structure containing Windows version information
static struct WindowsVersion {
    /// ditto
    string release, build, edition, insiderRing;

    /// Fetch all version info from registry
    static this() {
        try {
            key insiderInfo = Registry.localMachine.getKey("SOFTWARE\\Microsoft\\WindowsSelfHost\\Applicability", REGSAM.KEY_READ);
            insiderRing = insiderInfo.getValue("BranchName");
        } catch (RegistryException)
            insiderRing = null;

        try {
            Key currentVersion = Registry.localMachine.getKey("SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion", REGSAM.KEY_READ);

            release = currentVersion.getValue("ReleaseId").value_SZ;
            build = currentVersion.getValue("CurrentBuildNumber").value_SZ;
            edition = currentVersion.getValue("EditionID").value_SZ;
        } catch (RegistryException error) {
            debug writeln(error.message);
            release = build = edition = "unknown";
        }
    }
}

/// Get a config in the pattern of "^(?<key>[^:]+)\s*:\s*(?<value>.+)$" from a string.
string[string] parseConfig(const string config) {
    string[string] data;

    foreach (line; config.splitLines()) {
        line = line.stripLeft();
        
        if (!line.length || line[0 .. 2] == "//") // Ignore comments.
            continue;

        const size_t sepIndex = line.indexOf(":");

        const string key = line[0 .. sepIndex].strip();
        const string value = line[sepIndex + 1 .. $].strip();

        data[key] = value;
    }

    return data;
}

/// Open a URL by spawning a shell process to the browser executable, or system default.
void openUri(const string browserPath, const string args, const string url) {
    string execPath;

    if (["system_default", ""].canFind(browserPath))
        execPath = getSysDefaultBrowser().path;
    else
        execPath = browserPath;

    const string commandLine = "%s %s %s".format(escapeShellArg(execPath, false), args, escapeShellArg(url, false));

    STARTUPINFO_W lpStartupInfo = { STARTUPINFO_W.sizeof };
    PROCESS_INFORMATION lpProcessInformation;

    debug writeln(commandLine);

    const bool success = cast(bool) CreateProcessW(
        execPath.toUTF16z(), /* lpApplicationName */
        commandLine.toUTFz!(wchar*)(), /* lpCommandLine */
        null, /* lpProcessAttributes */
        null, /* lpThreadAttributes */
        true, /* bInheritHandles */
        CREATE_UNICODE_ENVIRONMENT | DETACHED_PROCESS, /* dwCreationFlags */
        null, /* lpEnvironment */
        null, /* lpCurrentDirectory */
        &lpStartupInfo, /* lpStartupInfo */
        &lpProcessInformation /* lpProcessInformation */
    );

    if (!success) {
        const uint messageId = MessageBox(null, "Search Deflector could not deflect the URI to your browser." ~
                "\nMake sure that the browser is still installed and that the executable still exists." ~
                "\n\nWould you like to see the full error message online?",
                "Search Deflector", MB_ICONWARNING | MB_YESNO);

        if (messageId == IDYES)
            createErrorDialog(ProcessException.newFromLastError("Failed to spawn new process"));
    }
}

/// Create an error dialog from the given exception
void createErrorDialog(const Throwable error, HWND hWnd = null) nothrow {
    // dfmt off
    try {
        const uint messageId = MessageBox(hWnd,
                "Search Deflector launch failed. Would you like to open the issues page to submit a bug report?" ~
                "\nThe important information will be filled out for you." ~
                "\n\nIf you do not wish to create a bug report, click 'No' to exit.",
                "Search Deflector", MB_ICONERROR | MB_YESNO);

        if (messageId == IDYES)
            browse("https://github.com/spikespaz/search-deflector/issues/new?body=" ~
                createIssueMessage(error).encodeComponent());
    } catch (Throwable) { // @suppress(dscanner.suspicious.catch_em_all)
        assert(0);
    }
    // dfmt on
}

/// Create a warning dialog with given message content
void createWarningDialog(const string message, HWND hWnd = null) nothrow {
    try {
        debug writeln(message);

        MessageBox(hWnd, message.toUTF16z, "Search Deflector", MB_ICONWARNING | MB_OK);
    } catch (Throwable error) // @suppress(dscanner.suspicious.catch_em_all)
        createErrorDialog(error);

}

/// Creates a GitHub issue body with the data from an Exception.
string createIssueMessage(const Throwable error) {
    auto winVer = WindowsVersion.get();

    // dfmt off
    return ISSUE_TEMPLATE.strip().formatString([
        "errorFile": error.file,
        "errorLine": error.line.to!string(),
        "errorMessage": error.message,
        "browserName": "",
        "browserPath": DeflectorSettings.browserPath,
        "useProfile": DeflectorSettings.useProfile.to!string(),
        "profileName": DeflectorSettings.profileName,
        "engineName": "",
        "engineUrl": DeflectorSettings.engineURL,
        "queryString": "",
        "queryUrl": "",
        "windowsRelease": winVer.release,
        "windowsBuild": winVer.build,
        "windowsEdition": winVer.edition,
        "insidersPreview": ""
    ]).to!string();
    // dfmt on
}

/// Return a string array of arguments that are parsed in ArgV style from a string.
string[] getConsoleArgs(const wchar* commandLine = GetCommandLineW()) {
    int argCount;
    wchar** argList = CommandLineToArgvW(commandLine, &argCount);
    string[] args;

    for (int index; index < argCount; index++)
        args ~= argList[index].to!string();

    return args;
}

/// Escape a command line argument according to the reference:
/// https://web.archive.org/web/20190109172835/https://blogs.msdn.microsoft.com/twistylittlepassagesallalike/2011/04/23/everyone-quotes-command-line-arguments-the-wrong-way/
string escapeShellArg(const string argument, bool force) {
    if (argument.length == 0)
        return "";

    if (!force && argument.indexOfAny(" \t\n\v\"") == -1)
        return argument;

    string escapedArg = "\"";

    for (uint pos = 0; pos < argument.length; pos++) {
        uint backslashCount = 0;
        
        while (pos != argument.length && argument[pos] == '\\') {
            pos++;
            backslashCount++;
        }

        if (pos == argument.length) {
            escapedArg ~= '\\'.repeat(backslashCount * 2).to!string();
            break;
        } else if (argument[pos] == '"')
            escapedArg ~= '\\'.repeat(backslashCount * 2 + 1).to!string() ~ '"';
        else
            escapedArg ~= '\\'.repeat(backslashCount).to!string() ~ argument[pos];
    }

    escapedArg ~= '"';

    return escapedArg;
}

/// Function to create a string from arguments that is properly escaped.
string escapeShellArgs(const string[] arguments) {
    string commandLine;

    foreach(string argument; arguments)
        commandLine ~= ' ' ~ escapeShellArg(argument, false);

    return commandLine;
}

/// Constructs all browser arguments from a DeflectorSettings object.
string getBrowserArgs() {
    string[] browserArgs;

    const bool isChrome = DeflectorSettings.browserPath.endsWith("chrome.exe");
    const bool isFirefox = DeflectorSettings.browserPath.endsWith("firefox.exe");

    if (DeflectorSettings.useProfile) {
        if (isChrome)
            browserArgs ~= "--profile-directory=" ~ escapeShellArg(DeflectorSettings.profileName, false);
        else if (isFirefox)
            browserArgs ~= ["-P", escapeShellArg(DeflectorSettings.profileName, false)];
    }

    return browserArgs.join(' ');
}

/// Try to fetch the engine presets from the repository, if it fails, read from local.
string[string] getEnginePresets() {
    string[string] engines = parseConfig(readText(buildPath(thisExePath().dirName(), "engines.txt")));

    try
        engines = mergeAAs(engines, parseConfig(get(ENGINE_TEMPLATES_URL).idup)); // Get the string of the resource content.
    catch (CurlException) {
    }

    return engines;
}

/// Fetch a list of available browsers from the Windows registry along with their paths.
/// Use the names as the keys in an associative array containing the browser executable paths.
string[string] getAvailableBrowsers(const bool currentUser = false) {
    string[string] availableBrowsers;
    Key startMenuInternetKey;

    if (currentUser)
        startMenuInternetKey = Registry.currentUser.getKey("SOFTWARE\\Clients\\StartMenuInternet");
    else
        startMenuInternetKey = Registry.localMachine.getKey("SOFTWARE\\Clients\\StartMenuInternet");

    foreach (key; startMenuInternetKey.keys) {
        string browserName;

        try
            browserName = key.getValue("").value_SZ;
        catch (RegistryException)
            continue;

        string browserPath = key.getKey("shell\\open\\command").getValue("").value_SZ;

        if (!isValidFilename(browserPath) && !exists(browserPath)) {
            browserPath = getConsoleArgs(browserPath.toUTF16z())[0];

            if (!isValidFilename(browserPath) && !exists(browserPath))
                continue;
        }

        availableBrowsers[browserName] = browserPath;
    }

    return availableBrowsers;
}

/// Get all of the installed browsers from system registry
string[string] getAllAvailableBrowsers() {
    auto browsers = getAvailableBrowsers(false);

    try
        return mergeAAs(browsers, getAvailableBrowsers(true));
    catch (RegistryException) {
    }

    return browsers;
}

/// Fetch the system default browser's program ID and executable path
Tuple!(string, "progID", string, "path") getSysDefaultBrowser() {
    Key userChoiceKey = Registry.currentUser.getKey("SOFTWARE\\Microsoft\\Windows\\Shell\\Associations\\UrlAssociations\\https\\UserChoice");
    const string progID = userChoiceKey.getValue("ProgID").value_SZ;
    Key progCommandKey = Registry.localMachine.getKey("SOFTWARE\\Classes\\" ~ progID ~ "\\shell\\open\\command");
    string browserPath = progCommandKey.getValue("").value_SZ;

    if (!isValidFilename(browserPath) && !exists(browserPath)) {
        browserPath = getConsoleArgs(browserPath.toUTF16z())[0];

        if (!isValidFilename(browserPath) && !exists(browserPath))
            throw new FileException(browserPath, "Browser executable path does not exist or is not valid.");
    }

    return tuple!("progID", "path")(progID, browserPath);
}

/// Get the browser name from known list of paths for installed browsers
string nameFromPath(const string[string] browsers, const string path) {
    if (["", "system_default"].canFind(path))
        return Translator.text("option.default_browser");

    foreach (browser; browsers.byKeyValue)
        if (browser.value == path)
            return browser.key;

    return "Custom";
}

/// Get the engine name by an engine URL from the known list
string nameFromUrl(const string[string] engines, const string url) {
    foreach (engine; engines.byKeyValue)
        if (engine.value == url)
            return engine.key;

    return "Custom";
}

/// Format a string by replacing each key with a value in replacements.
S formatString(S)(const S input, const S[S] replacements) {
    S output = input;

    foreach (variable; replacements.byKeyValue())
        output = output.replace("{{" ~ variable.key ~ "}}", variable.value);

    return output;
}

/// Merge two associative arrays, updating existing values in "baseAA" with new ones from "updateAA".
T[K] mergeAAs(T, K)(T[K] baseAA, T[K] updateAA) {
    T[K] newAA = baseAA;

    foreach (key; updateAA.byKey())
        newAA[key] = updateAA[key];

    return newAA;
}

/// Null comparison
bool isNull(T)(T value) if (is(T == class) || isPointer!T) {
    return value is null;
}