import { render, screen } from '@testing-library/react';
import { describe, it, expect } from 'vitest';
import StepInspector from '../StepInspector.tsx';

describe('StepInspector', () => {
  const defaultProps = {
    stepName: 'test_step',
    structure: {
      test_step: { type: 'step', depends_on: [] }
    },
    results: {},
    trace: [],
    inputs: {},
    stepAttempts: {
      test_step: 1
    }
  };

  it('should not show retries if there is only 1 attempt', () => {
    render(<StepInspector {...defaultProps} />);
    expect(screen.queryByText(/Retries:/)).not.toBeInTheDocument();
  });

  it('should show Retries: 1 if there are 2 attempts', () => {
    const props = {
      ...defaultProps,
      stepAttempts: {
        test_step: 2
      }
    };
    render(<StepInspector {...props} />);
    expect(screen.getByText('Retries: 1')).toBeInTheDocument();
  });

  it('should show Retries: 2 if there are 3 attempts', () => {
    const props = {
      ...defaultProps,
      stepAttempts: {
        test_step: 3
      }
    };
    render(<StepInspector {...props} />);
    expect(screen.getByText('Retries: 2')).toBeInTheDocument();
  });

  it('should not show retries if stepAttempts is missing for the step', () => {
    const props = {
      ...defaultProps,
      stepAttempts: {}
    };
    render(<StepInspector {...props} />);
    expect(screen.queryByText(/Retries:/)).not.toBeInTheDocument();
  });

  describe('Compensation History', () => {
    const propsWithUndo = {
      ...defaultProps,
      stepName: null, // Global View
      trace: [
        { type: 'run', step: 'step1', result: 'result1' },
        { type: 'run', step: 'step2', result: 'result2' },
        { type: 'compensate', step: 'step2', result: 'compensated step2' },
        { type: 'undo', step: 'step1', result: 'undid step1' }
      ]
    };

    it('should show compensation history in execution order (chronological)', () => {
      render(<StepInspector {...propsWithUndo} />);

      // Verify labels order (use exact match to avoid matching result blocks)
      const labels = screen.queryAllByText(/^step\d$/, { selector: 'span' });
      expect(labels[0]).toHaveTextContent('step2');
      expect(labels[1]).toHaveTextContent('step1');

      // Verify results are also in order
      expect(screen.getByText(/"compensated step2"/)).toBeInTheDocument();
      expect(screen.getByText(/"undid step1"/)).toBeInTheDocument();
    });

    it('should show the result of the undo/compensate operation', () => {
      render(<StepInspector {...propsWithUndo} />);

      expect(screen.getByText(/"compensated step2"/)).toBeInTheDocument();
      expect(screen.getByText(/"undid step1"/)).toBeInTheDocument();
    });

    it('should show COMPENSATE and UNDO labels', () => {
      render(<StepInspector {...propsWithUndo} />);

      expect(screen.getByText('compensate')).toBeInTheDocument();
      expect(screen.getByText('undo')).toBeInTheDocument();
    });
  });

  describe('Nested Reactor Support', () => {
    const mockStructure = {
      sub_reactor: {
        type: 'compose',
        nested_structure: {
          inner_step: { type: 'step' }
        }
      }
    };

    const mockComposedContexts = {
      sub_reactor: {
        context: {
          value: {
            intermediate_results: {
              inner_step: 'inner_result_value'
            },
            execution_trace: [
              { step: 'inner_step', type: 'run', arguments: { val: 456 } }
            ]
          }
        }
      }
    };

    it('correctly resolves and displays results for a nested step', () => {
      render(
        <StepInspector
          stepName="sub_reactor.inner_step"
          structure={mockStructure}
          results={{}}
          inputs={{}}
          trace={[]}
          composedContexts={mockComposedContexts}
        />
      );

      // Should show step name (base name only)
      expect(screen.getByText('inner_step')).toBeInTheDocument();

      // Should show resolved result
      expect(screen.getByText(/"inner_result_value"/)).toBeInTheDocument();

      // Should show resolved arguments from nested trace
      expect(screen.getByText(/456/)).toBeInTheDocument();
    });

    it('identifies failures in nested contexts', () => {
      const failedNestedContexts = {
        sub_reactor: {
          context: {
            value: {
              failure_reason: { step_name: 'inner_step', message: 'Nested failure' },
              intermediate_results: {},
              execution_trace: []
            }
          }
        }
      };

      render(
        <StepInspector
          stepName="sub_reactor.inner_step"
          structure={mockStructure}
          results={{}}
          inputs={{}}
          trace={[]}
          composedContexts={failedNestedContexts}
        />
      );

      expect(screen.getByText('Failure Details')).toBeInTheDocument();
      expect(screen.getByText('Nested failure')).toBeInTheDocument();
    });
  });
});
