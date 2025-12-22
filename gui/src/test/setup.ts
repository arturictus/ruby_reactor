import '@testing-library/jest-dom'
import { vi } from 'vitest'

// Polyfill ResizeObserver
class ResizeObserver {
  observe() { }
  unobserve() { }
  disconnect() { }
}
global.ResizeObserver = ResizeObserver
