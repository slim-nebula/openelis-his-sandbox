import { Alias } from '../interfaces';
export interface IIsMatchingAliasParams {
    requiredModule: string;
    alias: Alias;
}
export declare function isMatchingAlias(params: IIsMatchingAliasParams): boolean;
export declare function extractWildcardValue(requiredModule: string, alias: Alias): string;
export declare function removeAliasPrefix(requiredModule: string, alias: Alias): string;
