import { Authenticator } from "@aws-amplify/ui-react";
import "@aws-amplify/ui-react/styles.css";
import ControlPanel from "./ControlPanel";

export default function App() {
  return (
    <Authenticator loginMechanisms={["email"]} hideSignUp={false}>
      {({ signOut, user }) => (
        <ControlPanel
          email={user?.signInDetails?.loginId || user?.username || ""}
          onSignOut={signOut}
        />
      )}
    </Authenticator>
  );
}
