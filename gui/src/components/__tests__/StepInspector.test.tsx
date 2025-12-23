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
        { type: 'undo', step: 'step2', result: 'undid step2' },
        { type: 'undo', step: 'step1', result: 'undid step1' }
      ]
    };

    it('should show compensation history in execution order (chronological)', () => {
      render(<StepInspector {...propsWithUndo} />);

      const items = screen.getAllByText(/undid step/i);
      expect(items[0]).toHaveTextContent('undid step2');
      expect(items[1]).toHaveTextContent('undid step1');

      // Verify labels order (use exact match to avoid matching result blocks)
      expect(screen.getByText('step2', { selector: 'span' })).toBeInTheDocument();
      expect(screen.getByText('step1', { selector: 'span' })).toBeInTheDocument();

      const labels = screen.queryAllByText(/^step\d$/, { selector: 'span' });
      expect(labels[0]).toHaveTextContent('step2');
      expect(labels[1]).toHaveTextContent('step1');
    });

    it('should show the result of the undo operation, not the original arguments', () => {
      render(<StepInspector {...propsWithUndo} />);

      expect(screen.getByText(/"undid step2"/)).toBeInTheDocument();
      expect(screen.getByText(/"undid step1"/)).toBeInTheDocument();
    });
  });
});
