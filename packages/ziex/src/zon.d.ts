declare module '*.zon' {
    const content: string | number | boolean | null | JSON[] | { [key: string]: JSON };
    export default content;
  }