import { render, screen } from '@testing-library/react';
import { describe, it, expect } from 'vitest';
import CoordinationPanel, { CoordinationData } from '../CoordinationPanel';

describe('CoordinationPanel', () => {
  it('renders nothing when coordination is empty', () => {
    const { container } = render(<CoordinationPanel coordination={{}} />);
    expect(container.firstChild).toBeNull();
  });

  it('renders nothing when coordination is null', () => {
    const { container } = render(<CoordinationPanel coordination={null} />);
    expect(container.firstChild).toBeNull();
  });

  it('shows a held lock owned by this run', () => {
    const coordination: CoordinationData = {
      lock: {
        configured: { ttl: 60, wait: 0, auto_extend: true },
        key: 'user_42',
        state: {
          held: true,
          owner: 'ctx-abc',
          owned_by_this_context: true,
          reentrant_count: 1,
          ttl: 42,
        },
      },
    };

    render(<CoordinationPanel coordination={coordination} />);

    expect(screen.getByText('Coordination')).toBeInTheDocument();
    expect(screen.getByText('Lock')).toBeInTheDocument();
    expect(screen.getByText('user_42')).toBeInTheDocument();
    expect(screen.getByText('Held (this run)')).toBeInTheDocument();
    expect(screen.getByText('Expires: 42s')).toBeInTheDocument();
  });

  it('shows a free lock', () => {
    const coordination: CoordinationData = {
      lock: {
        configured: { ttl: 10, wait: 0, auto_extend: false },
        key: 'order:7',
        state: { held: false, ttl: -2 },
      },
    };

    render(<CoordinationPanel coordination={coordination} />);

    expect(screen.getByText('Free')).toBeInTheDocument();
    expect(screen.getByText('order:7')).toBeInTheDocument();
  });

  it('shows semaphore utilization', () => {
    const coordination: CoordinationData = {
      semaphore: {
        configured: { limit: 5, wait: 0 },
        key: 'geocode_api',
        state: { available: 3, held: 2, limit: 5 },
      },
    };

    render(<CoordinationPanel coordination={coordination} />);

    expect(screen.getByText('Semaphore')).toBeInTheDocument();
    expect(screen.getByText('geocode_api')).toBeInTheDocument();
    expect(screen.getByText('2 / 5 held')).toBeInTheDocument();
    expect(screen.getByText('3 available')).toBeInTheDocument();
  });

  it('shows rate-limit windows and period bucket state', () => {
    const coordination: CoordinationData = {
      rate_limit: {
        configured: {
          limits: [{ name: 'second', limit: 3, period_seconds: 1 }],
        },
        key: 'stripe:42',
        state: [{ name: 'second', limit: 3, period_seconds: 1, count: 2, ttl: 1 }],
      },
      period: {
        configured: { every: 'day' },
        key: 'daily_report:10',
        bucket_key: 'period:daily_report:10:2026-05-23',
        state: { marked: true, ttl: 86400 },
      },
    };

    render(<CoordinationPanel coordination={coordination} />);

    expect(screen.getByText('Rate Limit')).toBeInTheDocument();
    expect(screen.getByText('stripe:42')).toBeInTheDocument();
    expect(screen.getByText('2/3')).toBeInTheDocument();

    expect(screen.getByText('Period')).toBeInTheDocument();
    expect(screen.getByText('Bucket marked')).toBeInTheDocument();
    expect(screen.getByText('daily_report:10')).toBeInTheDocument();
  });

  it('shows key resolution errors', () => {
    const coordination: CoordinationData = {
      lock: {
        configured: { ttl: 60, wait: 0, auto_extend: true },
        key: null,
        key_error: 'missing input',
      },
    };

    render(<CoordinationPanel coordination={coordination} />);

    expect(screen.getByText('missing input')).toBeInTheDocument();
  });
});
