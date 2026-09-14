"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.removeAliasPrefix = exports.extractWildcardValue = exports.isMatchingAlias = void 0;
const utils_1 = require("../utils");
function escapeSpecialChars(str) {
    return str.replace(/[-[\]{}()*+?.,\\^$|#\s]/g, '\\$&');
}
function isMatchingAlias(params) {
    var _a, _b;
    const { requiredModule, alias } = params;
    const hasWildcard = (_a = alias.hasWildcard) !== null && _a !== void 0 ? _a : alias.shouldPrefixMatchWildly;
    const suffix = (_b = alias.suffix) !== null && _b !== void 0 ? _b : '';
    const { matched } = (0, utils_1.matchWildcard)({
        pattern: {
            prefix: alias.prefix,
            suffix,
            hasWildcard
        },
        text: requiredModule
    });
    return matched;
}
exports.isMatchingAlias = isMatchingAlias;
function extractWildcardValue(requiredModule, alias) {
    var _a, _b;
    const hasWildcard = (_a = alias.hasWildcard) !== null && _a !== void 0 ? _a : alias.shouldPrefixMatchWildly;
    const suffix = (_b = alias.suffix) !== null && _b !== void 0 ? _b : '';
    const { starValue } = (0, utils_1.matchWildcard)({
        pattern: {
            prefix: alias.prefix,
            suffix,
            hasWildcard
        },
        text: requiredModule
    });
    return starValue;
}
exports.extractWildcardValue = extractWildcardValue;
function removeAliasPrefix(requiredModule, alias) {
    const starVal = extractWildcardValue(requiredModule, alias);
    if (starVal)
        return starVal;
    const escapedPrefix = escapeSpecialChars(alias.prefix);
    const regex = new RegExp(`(?:^${escapedPrefix})|(?:\\.(?:[cm]?[jt]sx?|json)$)`, 'g');
    return requiredModule.replace(regex, '');
}
exports.removeAliasPrefix = removeAliasPrefix;
//# sourceMappingURL=default.replacer.match.js.map