import { render, screen } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import ReactorDetail from '../ReactorDetail.tsx';
import useSWR from 'swr';

// Mock dependencies
vi.mock('swr');
vi.mock('react-router-dom', () => ({
  useParams: () => ({ id: 'test-reactor-123' }),
  useNavigate: () => vi.fn(),
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
});
