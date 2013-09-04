<?php
  ini_set( 'display_errors', 1 );
  
  # Setup directory
  if ($setup_dir = getcwd()) {
    # Setup CGI script
    $setup_cgi_script = "$setup_dir/setup.cgi";
    
    # Chmod Setup CGI script
    if (chmod($setup_cgi_script, 0755)) {
      $setup_cgi_url = $_SERVER['PHP_SELF'];
      $setup_cgi_url = preg_replace('/\.php$/', '.cgi', $setup_cgi_url);
      header("Location: $setup_cgi_url");
      exit();
    }
    else {
      $error = "Can't $setup_cgi_script mode to 755";
    }
  }
  else {
    $error = "Can't change directory";
  }
?>

<!DOCTYPE html>
<html>
  <head>
    <title>Setup</title>
  </head>
  <body>
    <div class="container">
      <div class="text-center"><h1>Setup</h1></div>
    </div>
    <hr style="margin-top:0;margin-bottom:0">
    <div class="container">
      <div style="color:red">
        <?php echo $error ?>
      </div>
    </div>
  </body>
</html>
