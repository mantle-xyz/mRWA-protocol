// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

/**
 * @title LogUtil — Foundry 测试分级日志库（含小时轮转 + 错误兜底 + 等级开关）
 *
 * 两种初始化模式：
 *   1) legacy   : initLog(tag) 或 initLog(tag, filePath)
 *                 → 单文件、不轮转、不分等级（旧行为保留，向后兼容）
 *   2) rotating : initLog(tag, logDir, errorLogPath)
 *                 → 主日志按自然小时轮转：<logDir>/stress_<YYYYMMDD_HH>.log（追加）
 *                 → 所有 ERROR/CRIT 额外 append 到 errorLogPath（全局兜底）
 *                 → 支持 STRESS_LOG_LEVEL env（DEBUG/INFO/WARN/ERROR/CRIT，默认 INFO）
 *
 * foundry.toml 需要：
 *   fs_permissions = [{ access = "read-write", path = "." }]
 *
 * 注：vm.writeLine 对不存在的文件会自动创建并追加。
 */
contract LogUtil is Test {
    // ------------------------- Level constants -------------------------
    uint8 internal constant LV_DEBUG = 0;
    uint8 internal constant LV_INFO = 1;
    uint8 internal constant LV_WARN = 2;
    uint8 internal constant LV_ERROR = 3;
    uint8 internal constant LV_CRIT = 4;

    // ------------------------- State -----------------------------------
    string private _tag;

    // Legacy single-file mode
    string private _logFile;
    bool private _fileEnabled;

    // Rotating mode
    bool private _rotatingEnabled;
    string private _logBaseDir;
    string private _errorLogPath;
    uint256 private _currentHourBucket; // unix seconds / 3600
    string private _currentLogFile;

    // Level gating
    uint8 private _minLevel = LV_INFO;

    uint256 private constant BEIJING_OFFSET = 8 * 3600; // UTC+8

    // Level strings
    string private constant _S_DEBUG = "DEBUG";
    string private constant _S_INFO = "INFO";
    string private constant _S_WARN = "WARN";
    string private constant _S_ERROR = "ERROR";
    string private constant _S_CRIT = "CRIT";

    // ======================== 初始化 ========================

    /// @notice Legacy: 仅终端输出，设置 tag
    function initLog(string memory tag) internal {
        _tag = tag;
        _applyLevelFromEnv();
    }

    /// @notice Legacy: 终端 + 单文件输出（覆盖旧文件）
    function initLog(string memory tag, string memory filePath) internal {
        _tag = tag;
        _logFile = filePath;
        _fileEnabled = true;
        _rotatingEnabled = false;
        vm.writeFile(filePath, "");
        _applyLevelFromEnv();
    }

    /// @notice Rotating: 主日志按小时轮转，错误兜底到 errorLogPath
    function initLog(string memory tag, string memory logDir, string memory errorLogPath) internal {
        _tag = tag;
        _fileEnabled = false; // disable legacy single-file mode
        _rotatingEnabled = true;
        _logBaseDir = logDir;
        _errorLogPath = errorLogPath;
        _currentHourBucket = 0; // force rotation on first write
        _applyLevelFromEnv();
    }

    /// @notice Programmatic level setter (env takes precedence if set)
    function setLogLevel(uint8 lv) internal {
        _minLevel = lv;
    }

    // ======================== 纯消息 ========================

    function logDebug(string memory m) internal {
        _out(LV_DEBUG, _S_DEBUG, m);
    }

    function logInfo(string memory m) internal {
        _out(LV_INFO, _S_INFO, m);
    }

    function logWarn(string memory m) internal {
        _out(LV_WARN, _S_WARN, m);
    }

    function logError(string memory m) internal {
        _out(LV_ERROR, _S_ERROR, m);
    }

    function logCrit(string memory m) internal {
        _out(LV_CRIT, _S_CRIT, m);
    }

    // ======================== 消息 + uint256 ========================

    function logDebug(string memory l, uint256 v) internal {
        _out(LV_DEBUG, _S_DEBUG, l, vm.toString(v));
    }

    function logInfo(string memory l, uint256 v) internal {
        _out(LV_INFO, _S_INFO, l, vm.toString(v));
    }

    function logWarn(string memory l, uint256 v) internal {
        _out(LV_WARN, _S_WARN, l, vm.toString(v));
    }

    function logError(string memory l, uint256 v) internal {
        _out(LV_ERROR, _S_ERROR, l, vm.toString(v));
    }

    // ======================== 消息 + int256 ========================

    function logDebug(string memory l, int256 v) internal {
        _out(LV_DEBUG, _S_DEBUG, l, vm.toString(v));
    }

    function logInfo(string memory l, int256 v) internal {
        _out(LV_INFO, _S_INFO, l, vm.toString(v));
    }

    function logError(string memory l, int256 v) internal {
        _out(LV_ERROR, _S_ERROR, l, vm.toString(v));
    }

    // ======================== 消息 + address ========================

    function logDebug(string memory l, address a) internal {
        _out(LV_DEBUG, _S_DEBUG, l, vm.toString(a));
    }

    function logInfo(string memory l, address a) internal {
        _out(LV_INFO, _S_INFO, l, vm.toString(a));
    }

    function logWarn(string memory l, address a) internal {
        _out(LV_WARN, _S_WARN, l, vm.toString(a));
    }

    function logError(string memory l, address a) internal {
        _out(LV_ERROR, _S_ERROR, l, vm.toString(a));
    }

    // ======================== 消息 + bool ========================

    function logDebug(string memory l, bool v) internal {
        _out(LV_DEBUG, _S_DEBUG, l, v ? "true" : "false");
    }

    function logInfo(string memory l, bool v) internal {
        _out(LV_INFO, _S_INFO, l, v ? "true" : "false");
    }

    function logError(string memory l, bool v) internal {
        _out(LV_ERROR, _S_ERROR, l, v ? "true" : "false");
    }

    // ======================== 消息 + bytes32 ========================

    function logInfo(string memory l, bytes32 v) internal {
        _out(LV_INFO, _S_INFO, l, vm.toString(v));
    }

    function logDebug(string memory l, bytes32 v) internal {
        _out(LV_DEBUG, _S_DEBUG, l, vm.toString(v));
    }

    // ======================== 消息 + string ========================

    function logDebug(string memory l, string memory v) internal {
        _out(LV_DEBUG, _S_DEBUG, l, v);
    }

    function logInfo(string memory l, string memory v) internal {
        _out(LV_INFO, _S_INFO, l, v);
    }

    function logWarn(string memory l, string memory v) internal {
        _out(LV_WARN, _S_WARN, l, v);
    }

    function logError(string memory l, string memory v) internal {
        _out(LV_ERROR, _S_ERROR, l, v);
    }

    // ======================== 分隔线 ========================

    function logSep() internal {
        _out(LV_INFO, _S_INFO, "------------------------------------------------------------");
    }

    function logSep(string memory title) internal {
        _out(LV_INFO, _S_INFO, string.concat("-------------------- ", title, " --------------------"));
    }

    // ======================== 内部实现 ========================

    function _applyLevelFromEnv() private {
        string memory lvStr;
        try vm.envString("STRESS_LOG_LEVEL") returns (string memory s) {
            lvStr = s;
        } catch {
            return; // keep default
        }
        bytes32 h = keccak256(bytes(lvStr));
        if (h == keccak256("DEBUG") || h == keccak256("debug")) {
            _minLevel = LV_DEBUG;
        } else if (h == keccak256("INFO") || h == keccak256("info")) {
            _minLevel = LV_INFO;
        } else if (h == keccak256("WARN") || h == keccak256("warn")) {
            _minLevel = LV_WARN;
        } else if (h == keccak256("ERROR") || h == keccak256("error")) {
            _minLevel = LV_ERROR;
        } else if (h == keccak256("CRIT") || h == keccak256("crit")) {
            _minLevel = LV_CRIT;
        }
    }

    function _nowBeijing() private returns (uint256 sec, uint256 ms) {
        uint256 unixMs = vm.unixTime();
        sec = unixMs / 1000 + BEIJING_OFFSET;
        ms = unixMs % 1000;
    }

    /// @dev 在 rotating 模式下根据当前小时确保 _currentLogFile 指向正确文件
    function _ensureHourlyFile(uint256 sec) private {
        if (!_rotatingEnabled) return;
        uint256 hourBucket = sec / 3600;
        if (hourBucket == _currentHourBucket && bytes(_currentLogFile).length > 0) return;
        // (Re)compute current hourly filename
        (uint256 y, uint256 mo, uint256 d) = _daysToDate(sec / 86400);
        uint256 h = (sec % 86400) / 3600;
        string memory fname = string.concat(
            _logBaseDir,
            "/stress_",
            _pad4(y),
            _pad2(mo),
            _pad2(d),
            "_",
            _pad2(h),
            ".log"
        );
        _currentLogFile = fname;
        _currentHourBucket = hourBucket;
    }

    function _destFile() private view returns (string memory, bool) {
        if (_rotatingEnabled) return (_currentLogFile, true);
        if (_fileEnabled) return (_logFile, true);
        return ("", false);
    }

    function _writeTo(string memory line, uint8 levelInt) private {
        console.log(line);
        (string memory dest, bool ok) = _destFile();
        if (ok) vm.writeLine(dest, line);
        if (_rotatingEnabled && levelInt >= LV_ERROR && bytes(_errorLogPath).length > 0) {
            vm.writeLine(_errorLogPath, line);
        }
    }

    /// @dev 纯消息输出：yyyy-MM-dd HH:mm:ss,fff LEVEL message
    function _out(uint8 levelInt, string memory level, string memory m) private {
        if (levelInt < _minLevel) return;
        (uint256 sec, uint256 ms) = _nowBeijing();
        _ensureHourlyFile(sec);
        string memory line = string.concat(_formatTimestamp(sec, ms), " ", level, " ", m);
        _writeTo(line, levelInt);
    }

    /// @dev 标签+值输出：yyyy-MM-dd HH:mm:ss,fff LEVEL label: value（tag 已按用户要求去除）
    function _out(uint8 levelInt, string memory level, string memory l, string memory v) private {
        if (levelInt < _minLevel) return;
        (uint256 sec, uint256 ms) = _nowBeijing();
        _ensureHourlyFile(sec);
        string memory line = string.concat(_formatTimestamp(sec, ms), " ", level, " ", l, ": ", v);
        _writeTo(line, levelInt);
    }

    // ======================== 时间格式化 ========================

    function _formatTimestamp(uint256 ts, uint256 ms) private pure returns (string memory) {
        (uint256 y, uint256 mo, uint256 d) = _daysToDate(ts / 86400);
        uint256 rem = ts % 86400;
        uint256 h = rem / 3600;
        uint256 mi = (rem % 3600) / 60;
        uint256 s = rem % 60;

        return string.concat(
            _pad4(y), "-", _pad2(mo), "-", _pad2(d), " ", _pad2(h), ":", _pad2(mi), ":", _pad2(s), ",", _pad3(ms)
        );
    }

    function _daysToDate(uint256 totalDays) private pure returns (uint256 y, uint256 m, uint256 d) {
        int256 L = int256(totalDays) + 68569 + 2440588;
        int256 N = (4 * L) / 146097;
        L = L - (146097 * N + 3) / 4;
        int256 yi = (4000 * (L + 1)) / 1461001;
        L = L - (1461 * yi) / 4 + 31;
        int256 mi = (80 * L) / 2447;
        int256 di = L - (2447 * mi) / 80;
        L = mi / 11;
        mi = mi + 2 - 12 * L;
        yi = 100 * (N - 49) + yi + L;
        y = uint256(yi);
        m = uint256(mi);
        d = uint256(di);
    }

    function _pad2(uint256 v) private pure returns (string memory) {
        if (v < 10) return string.concat("0", _uint2str(v));
        return _uint2str(v);
    }

    function _pad3(uint256 v) private pure returns (string memory) {
        if (v < 10) return string.concat("00", _uint2str(v));
        if (v < 100) return string.concat("0", _uint2str(v));
        return _uint2str(v);
    }

    function _pad4(uint256 v) private pure returns (string memory) {
        if (v < 10) return string.concat("000", _uint2str(v));
        if (v < 100) return string.concat("00", _uint2str(v));
        if (v < 1000) return string.concat("0", _uint2str(v));
        return _uint2str(v);
    }

    function _uint2str(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        uint256 tmp = v;
        uint256 digits;
        while (tmp != 0) {
            digits++;
            tmp /= 10;
        }
        bytes memory buf = new bytes(digits);
        while (v != 0) {
            digits--;
            buf[digits] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        return string(buf);
    }
}
