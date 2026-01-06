import { render, screen, fireEvent } from '@testing-library/react';
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
              inner_step: 'inner_result_value',
              deep_reactor: 'deep_done'
            },
            execution_trace: [
              { step: 'inner_step', type: 'run', arguments: { val: 456 } }
            ],
            composed_contexts: {
              deep_reactor: {
                context: {
                  value: {
                    intermediate_results: {
                      deep_step: 'deep_result_value'
                    },
                    execution_trace: [
                      { step: 'deep_step', type: 'run', arguments: { deep_val: 789 } }
                    ]
                  }
                }
              }
            }
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

    it('correctly resolves and displays results for a deeply nested step', () => {
      render(
        <StepInspector
          stepName="sub_reactor.deep_reactor.deep_step"
          structure={{
            sub_reactor: {
              type: 'compose',
              nested_structure: {
                deep_reactor: {
                  type: 'compose',
                  nested_structure: {
                    deep_step: { type: 'step' }
                  }
                }
              }
            }
          }}
          results={{}}
          inputs={{}}
          trace={[]}
          composedContexts={mockComposedContexts}
        />
      );

      expect(screen.getByText('deep_step')).toBeInTheDocument();
      expect(screen.getByText(/"deep_result_value"/)).toBeInTheDocument();
      expect(screen.getByText(/789/)).toBeInTheDocument();
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

  describe('Recursive Compensation History', () => {
    const mockComposedContexts = {
      math_operation: {
        context: {
          value: {
            execution_trace: [
              { type: 'compensate', step: 'do_something', result: 'comp_val' },
              { type: 'undo', step: 'multiply', result: 'undo_val' }
            ],
            undo_stack: [
              { step_name: 'pending_step' }
            ]
          }
        }
      },
      child_reactor: {
        context: {
          value: {
            execution_trace: [
              { type: 'undo', step: 'wait_for', result: 'child_undo' }
            ]
          }
        }
      }
    };

    const props = {
      ...defaultProps,
      stepName: null, // Global View
      trace: [
        { type: 'compensate', step: 'math_operation', result: 'math_res' },
        { type: 'undo', step: 'child_reactor', result: 'child_res' }
      ],
      composedContexts: mockComposedContexts
    };

    it('should display grouped blocks for each reactor', () => {
      render(<StepInspector {...props} />);

      expect(screen.getByText('Root Reactor')).toBeInTheDocument();
      // math_operation and child_reactor appear twice (header and step)
      expect(screen.getAllByText('math_operation').length).toBe(2);
      expect(screen.getAllByText('child_reactor').length).toBe(2);
    });

    it('should recursively collect executed undo and compensate events', () => {
      render(<StepInspector {...props} />);

      // Root level (found twice as discussed)
      expect(screen.getAllByText('math_operation').length).toBe(2);
      expect(screen.getAllByText('child_reactor').length).toBe(2);

      // Nested math_operation level
      expect(screen.getByText('do_something')).toBeInTheDocument();
      expect(screen.getByText('multiply')).toBeInTheDocument();
      expect(screen.getByText(/"comp_val"/)).toBeInTheDocument();
      expect(screen.getByText(/"undo_val"/)).toBeInTheDocument();

      // Nested child_reactor level
      expect(screen.getByText('wait_for')).toBeInTheDocument();
      expect(screen.getByText(/"child_undo"/)).toBeInTheDocument();
    });

    it('should recursively collect pending items from undo_stack', () => {
      render(<StepInspector {...props} />);

      expect(screen.getByText('pending_step')).toBeInTheDocument();
      // Verify it's marked as pending
      expect(screen.getAllByText('pending').length).toBeGreaterThan(0);
    });
  });

  describe('Failure Information', () => {
    const failedProps = {
      ...defaultProps,
      stepName: 'failed_step',
      composedContexts: {
        failed_step: {
          context: {
            value: {
              status: 'failed',
              failure_reason: {
                message: 'Something went wrong',
                step_name: 'failed_step',
                exception_class: 'CustomError',
                backtrace: [
                  'line 1',
                  'line 2',
                  'line 3',
                  'line 4',
                  'line 5',
                  'line 6',
                  'line 7'
                ]
              },
              intermediate_results: {},
              execution_trace: []
            }
          }
        }
      },
      error: {
        message: 'Something went wrong',
        step_name: 'failed_step',
        exception_class: 'CustomError',
        backtrace: [
          'line 1',
          'line 2',
          'line 3',
          'line 4',
          'line 5',
          'line 6',
          'line 7'
        ]
      }
    };

    it('should display the exception class', () => {
      render(<StepInspector {...failedProps} />);
      expect(screen.getByText('CustomError')).toBeInTheDocument();
    });

    it('should truncate the backtrace to 5 lines by default', () => {
      render(<StepInspector {...failedProps} />);

      const backtraceText = screen.getByText(/line 1/);
      expect(backtraceText.textContent).toContain('line 5');
      expect(backtraceText.textContent).not.toContain('line 6');

      expect(screen.getByText(/Show More/)).toBeInTheDocument();
    });

    it('should expand the backtrace when clicking Show More', () => {
      render(<StepInspector {...failedProps} />);

      const showMoreButton = screen.getByText(/Show More/);
      fireEvent.click(showMoreButton);

      const backtraceText = screen.getByText(/line 1/);
      expect(backtraceText.textContent).toContain('line 7');
      expect(screen.getByText(/Show Less/)).toBeInTheDocument();
    });
  });

  describe('Validation Errors', () => {
    const validationErrorProps = {
      ...defaultProps,
      stepName: 'validation_step',
      composedContexts: {
        validation_step: {
          context: {
            value: {
              status: 'failed',
              failure_reason: {
                message: 'Validation failed',
                step_name: 'validation_step',
                validation_errors: {
                  field1: ['Error 1', 'Error 2'],
                  field2: 'Single Error'
                }
              },
              intermediate_results: {},
              execution_trace: []
            }
          }
        }
      },
      error: {
        message: 'Validation failed',
        step_name: 'validation_step',
        validation_errors: {
          field1: ['Error 1', 'Error 2'],
          field2: 'Single Error'
        }
      }
    };

    it('should display validation errors section', () => {
      render(<StepInspector {...validationErrorProps} />);
      expect(screen.getByText('Validation Errors')).toBeInTheDocument();
    });

    it('should display field names and error messages', () => {
      render(<StepInspector {...validationErrorProps} />);

      expect(screen.getByText('field1:')).toBeInTheDocument();
      expect(screen.getByText('- Error 1')).toBeInTheDocument();
      expect(screen.getByText('- Error 2')).toBeInTheDocument();

      expect(screen.getByText('field2:')).toBeInTheDocument();
      expect(screen.getByText('- Single Error')).toBeInTheDocument();
    });
  });
});
