"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.findResolvedAliasPath = void 0;
const utils_1 = require("../utils");
const default_replacer_match_1 = require("./default.replacer.match");
const normalizePath = require("normalize-path");
function resolveConcreteTarget(aliasPath, starValue) {
    const targetPattern = (0, utils_1.parseWildcardPattern)(aliasPath.path);
    if (targetPattern.hasWildcard) {
        return (0, utils_1.substituteWildcard)({ pattern: targetPattern, starValue });
    }
    if (starValue) {
        const sep = aliasPath.path ? '/' : '';
        return `${aliasPath.path}${sep}${starValue}`;
    }
    return aliasPath.path;
}
function checkSingleAliasPath(params) {
    const { aliasPath, requiredModule, alias, config } = params;
    const starValue = (0, default_replacer_match_1.extractWildcardValue)(requiredModule, alias);
    const concretePath = resolveConcreteTarget(aliasPath, starValue);
    const absolutePath = config.pathCache.getAbsoluteAliasPath(aliasPath.basePath, concretePath);
    config.output.debug('default replacer - absoluteAliasPath: ', absolutePath);
    if (absolutePath.startsWith('---')) {
        config.output.debug('default replacer - Invalid path');
        return null;
    }
    const resolvedPath = normalizePath(absolutePath);
    if (!config.pathCache.existsResolvedAlias(resolvedPath)) {
        config.output.debug('default replacer - Invalid path');
        return null;
    }
    return resolvedPath;
}
function findResolvedAliasPath(params) {
    const { alias, requiredModule, config } = params;
    for (const aliasPath of alias.paths) {
        const resolved = checkSingleAliasPath({
            aliasPath,
            requiredModule,
            alias,
            config
        });
        if (resolved)
            return resolved;
    }
    return null;
}
exports.findResolvedAliasPath = findResolvedAliasPath;
//# sourceMappingURL=default.replacer.path.js.map