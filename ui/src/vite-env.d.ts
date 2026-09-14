/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_SIGEO_MAP_API_BASE?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
