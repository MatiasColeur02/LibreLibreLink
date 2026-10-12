import jadx.api.*;
import java.io.File;
public class Dec {
  public static void main(String[] a) throws Exception {
    JadxArgs args = new JadxArgs();
    args.setInputFile(new File(a[0]));
    args.setOutDir(new File(a[1]));
    args.setThreadsCount(6);
    args.setSkipResources(true);
    args.setShowInconsistentCode(true);
    args.setDeobfuscationOn(false);
    try (JadxDecompiler d = new JadxDecompiler(args)) {
      d.load();
      d.save();
    }
  }
}
