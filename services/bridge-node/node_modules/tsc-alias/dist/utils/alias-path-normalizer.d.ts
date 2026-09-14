import { IProjectConfig } from '../interfaces';
export interface INormalizePathParams {
    path: string;
    config: IProjectConfig;
}
export declare function isDTS(extension: string): boolean;
export declare function normalizePathExtension(path: string): string;
export declare function normalizeAliasPath(params: INormalizePathParams): string;
