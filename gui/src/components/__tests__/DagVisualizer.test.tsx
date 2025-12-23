import { describe, it, expect, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import DagVisualizer from '../DagVisualizer.tsx';

// Mock ReactFlow to inspect nodes
vi.mock('@xyflow/react', async () => {
  const actual = await vi.importActual('@xyflow/react');
  return {
    ...actual,
    ReactFlow: vi.fn(({ nodes }) => (
      <div data-testid="react-flow-mock">
        {nodes.map((n: any) => (
          <div key={n.id} data-testid={`node-${n.id}`} data-status={n.data.status} data-label={n.data.label}>
            {n.id}
          </div>
        ))}
      </div>
    )),
    Handle: () => <div />,
    Position: { Top: 'top', Bottom: 'bottom' },
    Background: () => <div />,
    Controls: () => <div />,
  };
});

describe('DagVisualizer', () => {
  const mockStructure = {
    step1: { type: 'step', depends_on: [] },
    sub_reactor: {
      type: 'compose',
      depends_on: ['step1'],
      nested_structure: {
        inner_step: { type: 'step', depends_on: [] },
        deep_reactor: {
          type: 'compose',
          nested_structure: {
            deep_step: { type: 'step' }
          }
        }
      }
    }
  };

  const mockResults = {
    step1: 'done',
    sub_reactor: 'sub_done'
  };

  const mockComposedContexts = {
    sub_reactor: {
      context: {
        value: {
          status: 'completed',
          intermediate_results: {
            inner_step: 'inner_done',
            deep_reactor: 'deep_done'
          },
          composed_contexts: {
            deep_reactor: {
              context: {
                value: {
                  status: 'completed',
                  intermediate_results: {
                    deep_step: 'deep_value'
                  }
                }
              }
            }
          }
        }
      }
    }
  };

  it('generates unique path-based IDs for nested nodes', () => {
    render(
      <DagVisualizer
        structure={mockStructure}
        steps={[]}
        onStepSelect={() => { }}
        selectedStep={null}
      />
    );

    // Root nodes should have simple IDs
    expect(screen.queryByTestId('node-step1')).toBeInTheDocument();
    expect(screen.queryByTestId('node-sub_reactor')).toBeInTheDocument();

    // Nested nodes should have path-based IDs
    expect(screen.queryByTestId('node-sub_reactor.inner_step')).toBeInTheDocument();
    expect(screen.queryByTestId('node-sub_reactor.deep_reactor.deep_step')).toBeInTheDocument();
  });

  it('correctly resolves status for deeply nested nodes using composedContexts', () => {
    const { getByTestId } = render(
      <DagVisualizer
        structure={mockStructure}
        steps={[]}
        results={mockResults}
        composedContexts={mockComposedContexts}
        reactorStatus="running"
        onStepSelect={() => { }}
        selectedStep={null}
      />
    );

    // root step1 is completed
    expect(getByTestId('node-step1').getAttribute('data-status')).toBe('completed');

    // inner_step in sub_reactor is completed
    expect(getByTestId('node-sub_reactor.inner_step').getAttribute('data-status')).toBe('completed');

    // deep_step in deep_reactor is completed
    expect(getByTestId('node-sub_reactor.deep_reactor.deep_step').getAttribute('data-status')).toBe('completed');
  });

  it('marks unreached steps as cancelled if reactor failed', () => {
    const struct = {
      step1: { type: 'step' },
      step2: { type: 'step', depends_on: ['step1'] }
    };

    const { getByTestId } = render(
      <DagVisualizer
        structure={struct}
        steps={[]}
        results={{}}
        reactorStatus="failed"
        onStepSelect={() => { }}
        selectedStep={null}
      />
    );

    expect(getByTestId('node-step1').getAttribute('data-status')).toBe('cancelled');
    expect(getByTestId('node-step2').getAttribute('data-status')).toBe('cancelled');
  });
});


// End of file
