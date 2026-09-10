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
          <div
            key={n.id}
            data-testid={`node-${n.id}`}
            data-status={n.data.status}
            data-label={n.data.label}
            data-background={String(n.data.background)}
          >
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

  // A map with fail_fast false completes even when elements failed, so the
  // node's own status is the only place that can flag it.
  it('marks a map step failed when its elements failed', () => {
    const struct = { items: { type: 'map', depends_on: [] } };

    const { getByTestId, rerender } = render(
      <DagVisualizer
        structure={struct}
        steps={[]}
        results={{ items: { _type: 'map_results', total: 10, succeeded: 4, failed: 6, failures: [] } }}
        reactorStatus="completed"
        onStepSelect={() => { }}
        selectedStep={null}
      />
    );
    expect(getByTestId('node-items').getAttribute('data-status')).toBe('failed');

    rerender(
      <DagVisualizer
        structure={struct}
        steps={[]}
        results={{ items: { _type: 'map_results', total: 10, succeeded: 10, failed: 0, failures: [] } }}
        reactorStatus="completed"
        onStepSelect={() => { }}
        selectedStep={null}
      />
    );
    expect(getByTestId('node-items').getAttribute('data-status')).toBe('completed');
  });

  it('renders a skipped step as skipped, not completed, even though it stores a value', () => {
    const struct = {
      step1: { type: 'step' },
      step2: { type: 'step', depends_on: ['step1'] }
    };

    const { getByTestId } = render(
      <DagVisualizer
        structure={struct}
        steps={[{ type: 'skipped', step: 'step1' }]}
        results={{ step1: 'skipped_value', step2: 'done' }}
        reactorStatus="completed"
        onStepSelect={() => { }}
        selectedStep={null}
      />
    );

    expect(getByTestId('node-step1').getAttribute('data-status')).toBe('skipped');
    expect(getByTestId('node-step2').getAttribute('data-status')).toBe('completed');
  });

  it('marks worker-run steps from the stored background stamp', () => {
    const struct = {
      first: { type: 'step' },
      second: { type: 'step', depends_on: ['first'] },
      third: { type: 'step', depends_on: ['second'] }
    };

    const { getByTestId } = render(
      <DagVisualizer
        structure={struct}
        steps={[
          { type: 'run', step: 'first', background: false },
          { type: 'run', step: 'second', background: false },
          { type: 'run', step: 'third', background: true }
        ]}
        results={{ first: 'a', second: 'b', third: 'c' }}
        reactorStatus="completed"
        onStepSelect={() => { }}
        selectedStep={null}
      />
    );

    expect(getByTestId('node-first').getAttribute('data-background')).toBe('false');
    expect(getByTestId('node-second').getAttribute('data-background')).toBe('false');
    expect(getByTestId('node-third').getAttribute('data-background')).toBe('true');
  });

  it('marks the halting step as halted and leaves unreached nodes pending, not cancelled', () => {
    const struct = {
      step1: { type: 'step' },
      step2: { type: 'step', depends_on: ['step1'] }
    };

    const { getByTestId } = render(
      <DagVisualizer
        structure={struct}
        steps={[{ type: 'halt', step: 'step1' }]}
        results={{}}
        reactorStatus="halted"
        onStepSelect={() => { }}
        selectedStep={null}
      />
    );

    expect(getByTestId('node-step1').getAttribute('data-status')).toBe('halted');
    expect(getByTestId('node-step2').getAttribute('data-status')).toBe('pending');
  });

  it('marks a failed async_step from its dispatch record, not as cancelled', () => {
    const struct = {
      send_email: { type: 'async_step', depends_on: [] },
      later: { type: 'step', depends_on: ['send_email'] }
    };

    const { getByTestId } = render(
      <DagVisualizer
        structure={struct}
        steps={[]}
        results={{}}
        reactorStatus="failed"
        composedContexts={{
          send_email: {
            type: 'async_step_ref',
            name: 'send_email',
            record: {
              status: 'completed',
              success: false,
              result: { success: false, error: 'SMTP provider rejected the message' }
            }
          }
        }}
        onStepSelect={() => { }}
        selectedStep={null}
      />
    );

    expect(getByTestId('node-send_email').getAttribute('data-status')).toBe('failed');
    expect(getByTestId('node-later').getAttribute('data-status')).toBe('cancelled');
  });

  it('marks a successful async_step completed even when the parent failed', () => {
    const struct = { send_email: { type: 'async_step', depends_on: [] } };

    const { getByTestId } = render(
      <DagVisualizer
        structure={struct}
        steps={[]}
        results={{}}
        reactorStatus="failed"
        composedContexts={{
          send_email: {
            type: 'async_step_ref',
            record: { status: 'completed', success: true, result: { delivered: true } }
          }
        }}
        onStepSelect={() => { }}
        selectedStep={null}
      />
    );

    expect(getByTestId('node-send_email').getAttribute('data-status')).toBe('completed');
  });
});


// End of file
