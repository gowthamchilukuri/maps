import { defineAuth } from "@aws-amplify/backend";

/** Email/password Cognito for the Sigeo map admin console. */
export const auth = defineAuth({
  loginWith: {
    email: true,
  },
});
