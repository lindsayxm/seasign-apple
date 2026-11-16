// Vite's `?raw` suffix imports a file's text. Used for the .ics fixtures.
declare module "*.ics?raw" {
  const text: string;
  export default text;
}
