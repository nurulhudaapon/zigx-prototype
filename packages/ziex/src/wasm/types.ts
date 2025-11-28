
export type ComponentMetadata = {

};

export type InitOptions = {
  url?: string;
};

declare global {
  interface Window {
    _zx: Record<string, (...args: any[]) => void>;
  }
}