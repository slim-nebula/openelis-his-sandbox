/**
 * Errors that already know their status code, so a handler can throw one and
 * let the error middleware turn it into a response.
 *
 * Same shape as his-api's and patient-service's, deliberately: three services,
 * one exception hierarchy.
 */
export class HTTPError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
    this.name = this.constructor.name;
    Object.setPrototypeOf(this, new.target.prototype);
    Error.captureStackTrace?.(this, this.constructor);
  }
}

export class DomainError extends HTTPError {
  constructor(message: string) {
    super(400, message);
  }
}

export class NotFoundError extends HTTPError {
  constructor(message = 'Not found') {
    super(404, message);
  }
}

/**
 * A refusal that must answer in RFC 7807, because that is what the .NET service
 * did and what `/ops` callers parse. See problemResponse in the error
 * middleware.
 */
export class ProblemError extends HTTPError {}
