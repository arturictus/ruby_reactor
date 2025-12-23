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
});
