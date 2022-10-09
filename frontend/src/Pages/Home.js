import { Content } from "../Components/Page";
import { NavButton, InputGroup } from "../Components/Form";
import { InfoAnnouncement } from "../Components/Announcement";

export function Home() {
  return (
    <>
      <InfoAnnouncement id={1} />
      <InputGroup>
        <NavButton to={`/guide/rules`}>Rules</NavButton>
        <NavButton to={`/legal`}>Legal</NavButton>
      </InputGroup>
      <Content></Content>
    </>
  );
}
