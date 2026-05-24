import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import ReactorDetail from '../ReactorDetail.tsx';
import useSWR from 'swr';

const mockNavigate = vi.fn();
const mockFetch = vi.fn();

// Mock dependencies
vi.mock('swr');
vi.mock('react-router-dom', () => ({
  useParams: () => ({ id: 'test-reactor-123' }),
  useNavigate: () => mockNavigate,
  Link: ({ children }: { children: React.ReactNode }) => <a>{children}</a>
}));

// Mock child components to isolate tests
vi.mock('../DagVisualizer.tsx', () => ({
  default: ({ reactorStatus, error }: any) => (
    <div data-testid="dag-visualizer">
      <span data-testid="dag-status">{reactorStatus}</span>
      <span data-testid="dag-error">{error?.message}</span>
    </div>
  )
}));

vi.mock('../StepInspector.tsx', () => ({
  default: ({ error }: any) => (
    <div data-testid="step-inspector">
      <span data-testid="inspector-error">{error?.message}</span>
    </div>
  )
}));

describe('ReactorDetail', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.stubGlobal('fetch', mockFetch);
  });

  it('renders failure status correctly', () => {
    const mockError = {
      message: "Something went wrong",
      step_name: "step2",
      backtrace: ["line 1", "line 2"]
    };

    const mockData = {
      id: "test-reactor-123",
      class: "TestReactor",
      status: "failed",
      error: mockError,
      inputs: {},
      structure: {},
      steps: []
    };

    // Mock useSWR response
    (useSWR as any).mockReturnValue({
      data: mockData,
      error: null,
      isLoading: false,
      mutate: vi.fn()
    });

    render(<ReactorDetail />);

    // 1. Check Status Badge
    const statusBadges = screen.getAllByText('failed');
    // Find the one that is the badge (has class text-red-400), not the one in the graph
    const badge = statusBadges.find(el => el.classList.contains('text-red-400'));
    expect(badge).toBeInTheDocument();

    // 2. Check Failure Banner
    expect(screen.getByText('Workflow Failed')).toBeInTheDocument();
    // "Something went wrong" appears in multiple places (banner, mock props)
    expect(screen.getAllByText('Something went wrong').length).toBeGreaterThan(0);

    // 3. Check Props passed to DagVisualizer
    expect(screen.getByTestId('dag-status')).toHaveTextContent('failed');
    expect(screen.getByTestId('dag-error')).toHaveTextContent('Something went wrong');
  });

  it('renders success status correctly', () => {
    const mockData = {
      id: "test-reactor-123",
      class: "TestReactor",
      status: "completed",
      error: null,
      inputs: {},
      structure: {},
      steps: []
    };

    (useSWR as any).mockReturnValue({
      data: mockData,
      error: null,
      isLoading: false,
      mutate: vi.fn()
    });

    render(<ReactorDetail />);

    // 1. Check Status Badge
    const statusBadges = screen.getAllByText('completed');
    const badge = statusBadges.find(el => el.classList.contains('text-emerald-400'));
    expect(badge).toBeInTheDocument();

    expect(screen.queryByText('Workflow Failed')).not.toBeInTheDocument();

    // 2. Check Props passed to DagVisualizer
    expect(screen.getByTestId('dag-status')).toHaveTextContent('completed');
    expect(screen.getByTestId('dag-error')).toBeEmptyDOMElement();
  });

  it('enables retry only when reactor has failed', () => {
    const cases = [
      { status: 'failed', enabled: true },
      { status: 'running', enabled: false },
      { status: 'completed', enabled: false },
      { status: 'cancelled', enabled: false },
    ];

    cases.forEach(({ status, enabled }) => {
      (useSWR as any).mockReturnValue({
        data: {
          id: 'test-reactor-123',
          class: 'TestReactor',
          status,
          error: status === 'failed' ? { message: 'Something went wrong' } : null,
          inputs: {},
          structure: {},
          steps: []
        },
        error: null,
        isLoading: false,
        mutate: vi.fn()
      });

      const { unmount } = render(<ReactorDetail />);
      const retryButton = screen.getByRole('button', { name: /retry execution/i });

      if (enabled) {
        expect(retryButton).toBeEnabled();
      } else {
        expect(retryButton).toBeDisabled();
      }

      unmount();
    });
  });

  it('retries failed reactor and navigates to the new execution', async () => {
    (useSWR as any).mockReturnValue({
      data: {
        id: 'test-reactor-123',
        class: 'TestReactor',
        status: 'failed',
        error: { message: 'Something went wrong' },
        inputs: { should_fail: true },
        structure: {},
        steps: []
      },
      error: null,
      isLoading: false,
      mutate: vi.fn()
    });

    mockFetch.mockResolvedValue({
      ok: true,
      json: async () => ({ success: true, id: 'new-reactor-456' })
    });

    render(<ReactorDetail />);

    fireEvent.click(screen.getByRole('button', { name: /retry execution/i }));

    await waitFor(() => {
      expect(mockFetch).toHaveBeenCalledWith('/api/reactors/test-reactor-123/retry', { method: 'POST' });
      expect(mockNavigate).toHaveBeenCalledWith('/reactors/new-reactor-456');
    });
  });

  it('shows retry errors from the API', async () => {
    (useSWR as any).mockReturnValue({
      data: {
        id: 'test-reactor-123',
        class: 'TestReactor',
        status: 'failed',
        error: { message: 'Something went wrong' },
        inputs: {},
        structure: {},
        steps: []
      },
      error: null,
      isLoading: false,
      mutate: vi.fn()
    });

    mockFetch.mockResolvedValue({
      ok: false,
      json: async () => ({ error: 'Reactor can only be retried when failed' })
    });

    render(<ReactorDetail />);

    fireEvent.click(screen.getByRole('button', { name: /retry execution/i }));

    await waitFor(() => {
      expect(screen.getByText('Reactor can only be retried when failed')).toBeInTheDocument();
    });
    expect(mockNavigate).not.toHaveBeenCalled();
  });
});
