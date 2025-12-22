import '@testing-library/jest-dom'
// import { vi } from 'vitest'

// Polyfill ResizeObserver
class ResizeObserver {
  observe() { }
  unobserve() { }
  disconnect() { }
}
// @ts-ignore
globalThis.ResizeObserver = ResizeObserver
