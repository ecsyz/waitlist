import { Content } from "../Components/Page";
import { InfoAnnouncement } from "../Components/Announcement";

export function Home() {
  return (
    <>
      <InfoAnnouncement id={1} />
      <Content></Content>
    </>
  );
}
