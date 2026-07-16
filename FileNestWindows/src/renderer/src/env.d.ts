/// <reference types="vite/client" />

import type { FileNestApi } from '../../shared/types'

declare global {
  interface Window {
    fileNest: FileNestApi
  }
}

export {}
